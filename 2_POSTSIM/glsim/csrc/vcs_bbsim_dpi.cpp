#include <elf.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <deque>
#include <map>
#include <string>
#include <vector>

#include "svdpi.h"
#include "vpi_user.h"

struct Backing {
  uint8_t *data;
  uint64_t size;
};

struct ReadResp {
  int id;
  uint64_t data;
  bool last;
};

struct MagicMem {
  uint64_t mem_base;
  uint64_t mem_size;
  uint64_t word_size;
  uint64_t line_size;
  uint64_t store_addr;
  int store_id;
  uint64_t store_size;
  uint64_t store_count;
  bool store_inflight;
  bool ar_ready_v;
  bool aw_ready_v;
  bool w_ready_v;
  std::deque<int> bresp;
  std::deque<ReadResp> rresp;
  Backing backing;
};

static std::vector<std::map<long long, Backing>> g_mem_data;
static std::string g_elf_file;
static FILE *g_uart_fp = nullptr;
static FILE *g_itrace_fp = nullptr;
static uint64_t g_bdb_rtl_clk = 0;

static void scan_plusargs() {
  static bool scanned = false;
  if (scanned)
    return;
  scanned = true;

  s_vpi_vlog_info info;
  if (!vpi_get_vlog_info(&info))
    return;
  for (int i = 1; i < info.argc; i++) {
    std::string arg(info.argv[i]);
    if (arg.find("+elf=") == 0)
      g_elf_file = arg.substr(strlen("+elf="));
  }
}

static void load_elf_to_mem(const char *path, uint8_t *data, uint64_t mem_base,
                            uint64_t mem_size) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    fprintf(stderr, "[BBSimDRAM] Cannot open ELF: %s\n", path);
    abort();
  }

  struct stat st;
  if (fstat(fd, &st) != 0) {
    fprintf(stderr, "[BBSimDRAM] fstat failed for ELF: %s\n", path);
    abort();
  }

  size_t file_size = (size_t)st.st_size;
  uint8_t *file_buf =
      (uint8_t *)mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (file_buf == MAP_FAILED) {
    fprintf(stderr, "[BBSimDRAM] mmap failed for ELF: %s\n", path);
    abort();
  }

  Elf64_Ehdr *ehdr = (Elf64_Ehdr *)file_buf;
  if (memcmp(ehdr->e_ident, ELFMAG, SELFMAG) != 0) {
    fprintf(stderr, "[BBSimDRAM] Not a valid ELF file: %s\n", path);
    abort();
  }
  if (ehdr->e_ident[EI_CLASS] != ELFCLASS64) {
    fprintf(stderr, "[BBSimDRAM] Only ELF64 supported\n");
    abort();
  }

  Elf64_Phdr *phdrs = (Elf64_Phdr *)(file_buf + ehdr->e_phoff);
  size_t loaded = 0;
  for (int i = 0; i < ehdr->e_phnum; i++) {
    Elf64_Phdr *ph = &phdrs[i];
    if (ph->p_type != PT_LOAD || ph->p_filesz == 0)
      continue;

    uint64_t paddr = ph->p_paddr;
    if (paddr < mem_base || paddr + ph->p_memsz > mem_base + mem_size) {
      fprintf(stderr,
              "[BBSimDRAM] Segment paddr=0x%lx size=0x%lx outside mem "
              "[0x%lx, 0x%lx)\n",
              paddr, ph->p_memsz, mem_base, mem_base + mem_size);
      abort();
    }

    uint64_t offset = paddr - mem_base;
    memcpy(data + offset, file_buf + ph->p_offset, ph->p_filesz);
    if (ph->p_memsz > ph->p_filesz)
      memset(data + offset + ph->p_filesz, 0, ph->p_memsz - ph->p_filesz);
    loaded += ph->p_filesz;
  }

  munmap(file_buf, file_size);
  printf("[BBSimDRAM] Loaded ELF '%s': %zu bytes\n", path, loaded);
  fflush(stdout);
}

static void mem_write(MagicMem *mm, uint64_t faddr, uint64_t wdata,
                      uint64_t strb, uint64_t size) {
  uint64_t addr = faddr - mm->mem_base;
  if (addr >= mm->mem_size) {
    fprintf(stderr, "[BBSimDRAM] write addr 0x%lx outside memory\n", faddr);
    abort();
  }
  if (size != sizeof(uint64_t) * 8)
    strb &= ((1ULL << size) - 1) << (addr % mm->word_size);

  uint8_t *src = (uint8_t *)&wdata;
  uint8_t *base = mm->backing.data + (addr / mm->word_size) * mm->word_size;
  for (uint64_t i = 0; i < mm->word_size; i++) {
    if (strb & 1)
      base[i] = src[i];
    strb >>= 1;
  }
}

static uint64_t mem_read(MagicMem *mm, uint64_t faddr) {
  uint64_t addr = faddr - mm->mem_base;
  if (addr >= mm->mem_size) {
    fprintf(stderr, "[BBSimDRAM] read addr 0x%lx outside memory\n", faddr);
    abort();
  }
  uint64_t value = 0;
  memcpy(&value, mm->backing.data + addr, mm->word_size);
  return value;
}

extern "C" void *bbsim_memory_init(int chip_id, long long mem_size,
                                    long long word_size, long long line_size,
                                    long long id_bits, long long clock_hz,
                                    long long mem_base) {
  (void)id_bits;
  (void)clock_hz;
  scan_plusargs();

  while (chip_id >= (int)g_mem_data.size())
    g_mem_data.push_back(std::map<long long, Backing>());

  Backing backing;
  if (g_mem_data[chip_id].find(mem_base) != g_mem_data[chip_id].end()) {
    backing = g_mem_data[chip_id][mem_base];
  } else {
    uint8_t *data = (uint8_t *)mmap(NULL, mem_size, PROT_READ | PROT_WRITE,
                                    MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (data == MAP_FAILED) {
      fprintf(stderr, "[BBSimDRAM] mmap for backing store failed\n");
      abort();
    }
    memset(data, 0, mem_size);
    if (!g_elf_file.empty())
      load_elf_to_mem(g_elf_file.c_str(), data, (uint64_t)mem_base,
                      (uint64_t)mem_size);
    backing = {data, (uint64_t)mem_size};
    g_mem_data[chip_id][mem_base] = backing;
  }

  MagicMem *mm = new MagicMem();
  mm->mem_base = (uint64_t)mem_base;
  mm->mem_size = (uint64_t)mem_size;
  mm->word_size = (uint64_t)word_size;
  mm->line_size = (uint64_t)line_size;
  mm->store_addr = 0;
  mm->store_id = 0;
  mm->store_size = 0;
  mm->store_count = 0;
  mm->store_inflight = false;
  mm->ar_ready_v = true;
  mm->aw_ready_v = true;
  mm->w_ready_v = false;
  mm->backing = backing;
  return mm;
}

extern "C" void bbsim_memory_tick(
    void *channel, unsigned char reset, unsigned char ar_valid,
    unsigned char *ar_ready, long long ar_addr, int ar_id, int ar_size,
    int ar_len, unsigned char aw_valid, unsigned char *aw_ready,
    long long aw_addr, int aw_id, int aw_size, int aw_len,
    unsigned char w_valid, unsigned char *w_ready, int w_strb, long long w_data,
    unsigned char w_last, unsigned char *r_valid, unsigned char r_ready,
    int *r_id, int *r_resp, long long *r_data, unsigned char *r_last,
    unsigned char *b_valid, unsigned char b_ready, int *b_id, int *b_resp) {
  MagicMem *mm = (MagicMem *)channel;
  bool ar_fire = !reset && ar_valid && true;
  bool aw_fire = !reset && aw_valid && !mm->store_inflight;
  bool w_fire = !reset && w_valid && mm->store_inflight;
  bool r_fire = !reset && !mm->rresp.empty() && r_ready;
  bool b_fire = !reset && !mm->bresp.empty() && b_ready;

  if (ar_fire) {
    uint64_t start_addr = ((uint64_t)ar_addr / mm->word_size) * mm->word_size;
    for (int i = 0; i <= ar_len; i++) {
      mm->rresp.push_back(
          ReadResp{ar_id, mem_read(mm, start_addr + i * mm->word_size),
                   i == ar_len});
    }
  }

  if (aw_fire) {
    mm->store_addr = (uint64_t)aw_addr;
    mm->store_id = aw_id;
    mm->store_count = (uint64_t)aw_len + 1;
    mm->store_size = 1ULL << aw_size;
    mm->store_inflight = true;
  }

  if (w_fire) {
    mem_write(mm, mm->store_addr, (uint64_t)w_data, (uint64_t)w_strb,
              mm->store_size);
    mm->store_addr += mm->store_size;
    mm->store_count--;
    if (mm->store_count == 0) {
      mm->store_inflight = false;
      mm->bresp.push_back(mm->store_id);
      if (!w_last) {
        fprintf(stderr, "[BBSimDRAM] write burst completed without w_last\n");
        abort();
      }
    }
  }

  if (b_fire)
    mm->bresp.pop_front();
  if (r_fire)
    mm->rresp.pop_front();

  if (reset) {
    mm->bresp.clear();
    mm->rresp.clear();
    mm->store_inflight = false;
  }

  *ar_ready = 1;
  *aw_ready = !mm->store_inflight;
  *w_ready = mm->store_inflight;
  *r_valid = !mm->rresp.empty();
  *r_id = *r_valid ? mm->rresp.front().id : 0;
  *r_resp = 0;
  *r_data = *r_valid ? (long long)mm->rresp.front().data : 0;
  *r_last = *r_valid ? mm->rresp.front().last : 0;
  *b_valid = !mm->bresp.empty();
  *b_id = *b_valid ? mm->bresp.front() : 0;
  *b_resp = 0;
}

static const char *plusarg_value(const char *prefix) {
  scan_plusargs();
  s_vpi_vlog_info info;
  if (!vpi_get_vlog_info(&info))
    return nullptr;
  size_t n = strlen(prefix);
  for (int i = 1; i < info.argc; i++) {
    if (strncmp(info.argv[i], prefix, n) == 0)
      return info.argv[i] + n;
  }
  return nullptr;
}

extern "C" void scu_uart_write(uint32_t hart_id, uint32_t ch) {
  (void)hart_id;
  if (!g_uart_fp) {
    const char *path = plusarg_value("+stdout=");
    g_uart_fp = fopen(path ? path : "stdout.log", "w");
  }
  if (g_uart_fp) {
    fputc((char)(ch & 0xff), g_uart_fp);
    fflush(g_uart_fp);
  }
  fputc((char)(ch & 0xff), stdout);
  fflush(stdout);
}

extern "C" int scu_uart_rx_valid(uint32_t hart_id) {
  (void)hart_id;
  return 0;
}

extern "C" void scu_uart_rx_sample(uint32_t hart_id, uint32_t pop,
                                    uint32_t *valid, uint32_t *data) {
  (void)hart_id;
  (void)pop;
  *valid = 0;
  *data = 0;
}

extern "C" void scu_sim_exit(uint32_t hart_id, uint32_t code) {
  if (code == 0)
    fprintf(stderr, "[SCU] hart %u: simulation success\n", hart_id);
  else
    fprintf(stderr, "[SCU] hart %u: simulation exit code %u\n", hart_id, code);
  if (g_uart_fp)
    fclose(g_uart_fp);
  vpi_control(vpiFinish, code);
}

extern "C" void dpi_bdb_set_clk(unsigned long long c) { g_bdb_rtl_clk = c; }

extern "C" void dpi_itrace(unsigned char is_issue, unsigned int rob_id,
                            unsigned int domain_id, unsigned int funct,
                            unsigned long long pc, unsigned long long rs1,
                            unsigned long long rs2,
                            unsigned char bank_enable) {
  (void)rs1;
  (void)rs2;
  if (!g_itrace_fp) {
    const char *path = plusarg_value("+itrace_log=");
    if (path)
      g_itrace_fp = fopen(path, "w");
  }
  if (g_itrace_fp) {
    fprintf(g_itrace_fp,
            "cycle=%llu kind=%u rob=%u domain=%u funct=0x%x pc=0x%016llx "
            "bank=0x%x\n",
            g_bdb_rtl_clk, is_issue, rob_id, domain_id, funct, pc,
            bank_enable);
  }
}

extern "C" void dpi_mtrace(unsigned char is_write, unsigned char is_shared,
                            unsigned int channel, unsigned long long hart_id,
                            unsigned int vbank_id, unsigned int pbank_id,
                            unsigned int group_id, unsigned int addr,
                            unsigned long long data_lo,
                            unsigned long long data_hi) {
  (void)is_write;
  (void)is_shared;
  (void)channel;
  (void)hart_id;
  (void)vbank_id;
  (void)pbank_id;
  (void)group_id;
  (void)addr;
  (void)data_lo;
  (void)data_hi;
}

extern "C" void dpi_pmctrace(unsigned int ball_id, unsigned int rob_id,
                              unsigned long long elapsed) {
  (void)ball_id;
  (void)rob_id;
  (void)elapsed;
}

extern "C" void dpi_mem_pmctrace(unsigned char is_store, unsigned int rob_id,
                                  unsigned long long elapsed) {
  (void)is_store;
  (void)rob_id;
  (void)elapsed;
}
