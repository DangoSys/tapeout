# Gate-Level Simulation 完整执行计划

## 目标
用 VCS 跑综合后的 `ChipTop.v` 门级网表，生成高覆盖率的 SAIF/VCD 供 PTPX 功耗分析，解决当前 RTL VCD 只有 14% annotation 的问题。

## 核心策略
- 复用 buckyball Chipyard 已验证的 `BBSimHarness` + DPI-C（内存/UART/时钟）
- 只替换 `chiptop0` 实例：从 RTL `ChipTop.sv` 换成综合网表 `ChipTop.v`
- 链入 std cell + SRAM 的 Verilog 仿真模型
- VCS 重新编译 DPI C++ 源码（`arch/src/csrc/src/monitor/**`，剔除 Verilator 专属 `main.cc`）
- 输出 SAIF（推荐）+ VCD，在 reset 后才开始 activity annotation

---

## 阶段 0：前置核对（必须先确认，否则后续白做）

### 0.1 确认 DPI C++ 代码无 Verilator 依赖
```bash
# 检查 csrc 是否引入 verilated.h / verilated_fst_c.h（VCS 不支持）
cd ~/buckyball/arch/src/csrc
grep -rn 'verilated' src/monitor/ --include='*.cc' --include='*.h'
# 预期：只有 src/main.cc 有 Verilated 引用（已知要剔除）
# 若 monitor.cc / bdb_clk.cc / mmio.cc 也引用了 Verilated*，需手动改成 VCS 兼容形式
```

**决策点**：
- ✅ 若只有 `main.cc` 引用 Verilated → 继续
- ❌ 若 `monitor/*.cc` 也依赖 → 需先改写 DPI 实现（风险中等，预估 2-4 小时）

### 0.2 定位原 RTL sim 的 workload
```bash
# 找到上次生成 waveform.vcd 的命令/脚本
cd ~/buckyball/arch
ls -lt waveform/ log/ | head -20
# 确认 ELF 路径，例如 bb-tests/output/workloads/src/CTest/toy/...
```

**需获取**：
- 具体的 ELF 二进制路径（例如 `~/buckyball/bb-tests/output/.../toy-baremetal`）
- 仿真参数（`+elf=...` / `+batch` / `+trace=all`）
- reset 周期数（gate-level 需更长 reset，预估 100-200 cycle）

---

## 阶段 1：准备仿真模型文件（一次性工作）

### 1.1 解包 std cell Verilog 模型
```bash
cd /home/sjm/tapeout
mkdir -p 1_PRESIM/glsim/models/std_cell
cd 1_PRESIM/glsim/models/std_cell

tar xzf /data0/tsmc28/TSMC28/logic/tcbn28hpcplusbwp40p140_180b/AN61001_20180509/tcbn28hpcplusbwp40p140_110a_vlg.tar.gz

# 验证解包结果
ls TSMCHOME/digital/Front_End/verilog/tcbn28hpcplusbwp40p140_110a/
# 预期：tcbn28hpcplusbwp40p140.v  tcbn28hpcplusbwp40p140_pwr.v
```

**输出**：
- `1_PRESIM/glsim/models/std_cell/TSMCHOME/digital/Front_End/verilog/tcbn28hpcplusbwp40p140_110a/tcbn28hpcplusbwp40p140.v`

### 1.2 收集 SRAM Verilog 模型清单
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim
python3 << 'EOF'
import csv
from pathlib import Path

manifest = Path("../../0_RTL/real_sram_libs/macro_manifest.csv")
with open(manifest) as f:
    reader = csv.DictReader(f)
    verilog_files = set()
    for row in reader:
        for vfile in row["verilog_files"].split():
            verilog_files.add(vfile.strip())

with open("sram_verilog_files.txt", "w") as out:
    for vf in sorted(verilog_files):
        out.write(vf + "\n")

print(f"收集到 {len(verilog_files)} 个 SRAM Verilog 文件")
EOF

# 验证
head sram_verilog_files.txt
wc -l sram_verilog_files.txt
```

**输出**：
- `1_PRESIM/glsim/sram_verilog_files.txt`（约 50-100 个 `.v` 文件路径）

### 1.3 收集 harness SystemVerilog 文件清单
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim
HARNESS_DIR=~/buckyball/arch/build/sims.verilator.BuckyballToyVerilatorConfig

# 列出所有 .sv 和 .v，排除 ChipTop.sv（要用网表替换）
find "$HARNESS_DIR" -maxdepth 1 \( -name '*.sv' -o -name '*.v' \) \
  ! -name 'ChipTop.sv' \
  | sort > harness_sv_files.txt

# 验证（应包含 BBSimHarness.sv, BBSimDRAM.v, SCU*DPI.v, BdbClkDPI.v, *TraceDPI.v 等）
head harness_sv_files.txt
wc -l harness_sv_files.txt
```

**输出**：
- `1_PRESIM/glsim/harness_sv_files.txt`（约 400+ 个 `.sv/.v` 文件）

### 1.4 收集 DPI C++ 源文件清单（剔除 main.cc）
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim
CSRC_DIR=~/buckyball/arch/src/csrc

find "$CSRC_DIR/src/monitor" -name '*.cc' | sort > dpi_cc_files.txt

# 验证（不应包含 main.cc）
cat dpi_cc_files.txt
grep -q 'main.cc' dpi_cc_files.txt && echo "错误：包含 main.cc" || echo "正确：已剔除 main.cc"
```

**输出**：
- `1_PRESIM/glsim/dpi_cc_files.txt`（约 15 个 `.cc`，包括 `BBSimDRAM.cc`, `mmio.cc`, `bdb_clk.cc`, `*trace.cc` 等）

---

## 阶段 2：编写仿真文件

### 2.1 创建 VCS filelist
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim
cat > filelist.f << 'EOF'
# timescale 统一由模型定义
+define+SYNTHESIS
+define+VCS

# 1. 网表 ChipTop（替换 RTL）
/home/sjm/tapeout/3_POWER/netlist/ChipTop.v

# 2. harness SystemVerilog（除 ChipTop.sv 外全部）
-f harness_sv_files.txt

# 3. std cell 仿真模型
models/std_cell/TSMCHOME/digital/Front_End/verilog/tcbn28hpcplusbwp40p140_110a/tcbn28hpcplusbwp40p140.v

# 4. SRAM 仿真模型
-f sram_verilog_files.txt

# 5. testbench
tb_glsim.sv

# 包含路径
+incdir+/home/sjm/buckyball/arch/src/csrc/include
EOF
```

### 2.2 创建 testbench（控制 reset/SAIF/VCD）
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim
cat > tb_glsim.sv << 'EOF'
`timescale 1ns/1ps

module tb_glsim;
  // 无需显式例化 BBSimHarness，VCS 自动识别顶层
  // BBSimHarness 内部已包含 chiptop0 (ChipTop 网表) + DPI 模块

  string saif_file, vcd_file, elf_file;
  int reset_cycles = 200;
  int warmup_cycles = 1000;  // reset 后预热周期，等流水线稳定

  initial begin
    // 读取运行时参数
    if (!$value$plusargs("saif=%s", saif_file)) saif_file = "glsim.saif";
    if (!$value$plusargs("vcd=%s", vcd_file)) vcd_file = "glsim.vcd";
    if (!$value$plusargs("reset_cycles=%d", reset_cycles)) reset_cycles = 200;
    if (!$value$plusargs("warmup_cycles=%d", warmup_cycles)) warmup_cycles = 1000;

    $display("[tb_glsim] SAIF: %s, VCD: %s", saif_file, vcd_file);
    $display("[tb_glsim] reset_cycles=%0d, warmup_cycles=%0d", reset_cycles, warmup_cycles);

    // 等待 reset 释放 + 预热
    repeat (reset_cycles + warmup_cycles) @(posedge BBSimHarness.clock);
    $display("[tb_glsim] %t: 开始 activity annotation", $time);

    // SAIF：标记整个 chiptop0
    $set_gate_level_monitoring("on");
    $set_toggle_region(BBSimHarness.chiptop0);
    $toggle_start();

    // VCD：只 dump chiptop0（避免过大）
    $dumpfile(vcd_file);
    $dumpvars(0, BBSimHarness.chiptop0);
  end

  // 监控 SCU exit 信号（DPI 会调 $finish）
  // 或设置最大 cycle 超时
  initial begin
    #1000000000;  // 1s 超时（根据 workload 调整）
    $display("[tb_glsim] 超时退出");
    $finish;
  end

  final begin
    $toggle_stop();
    $toggle_report(saif_file, 1.0e-9, "BBSimHarness.chiptop0");
    $display("[tb_glsim] SAIF 已写入 %s", saif_file);
  end
endmodule
EOF
```

### 2.3 创建 VCS 编译脚本
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim
cat > compile.sh << 'EOFSH'
#!/bin/bash
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

source ../../config/env.sh

CSRC_DIR=~/buckyball/arch/src/csrc
RESULT_DIR=~/buckyball/result

# C++ 编译选项
CFLAGS="-std=c++17 -DBBSIM -I${CSRC_DIR}/include -I${RESULT_DIR}/include"
CFLAGS="$CFLAGS $(pkg-config --cflags readline 2>/dev/null || echo '')"

# 链接选项
LDFLAGS="-ldramsim -lelf -lreadline -lstdc++ -lz"
LDFLAGS="$LDFLAGS -L${RESULT_DIR}/lib -Wl,-rpath,${RESULT_DIR}/lib"
LDFLAGS="$LDFLAGS $(pkg-config --libs-only-L --libs-only-other readline 2>/dev/null || echo '')"

# 收集 DPI C++ 源文件
DPI_SOURCES=$(cat dpi_cc_files.txt | tr '\n' ' ')

echo "=== VCS 编译 gate-level simulation ==="
echo "DPI C++ 源: $DPI_SOURCES"
echo "CFLAGS: $CFLAGS"
echo "LDFLAGS: $LDFLAGS"

vcs -full64 -sverilog \
  -f filelist.f \
  -debug_access+all \
  -timescale=1ns/1ps \
  +vcs+initreg+random \
  -CFLAGS "$CFLAGS" \
  $DPI_SOURCES \
  -LDFLAGS "$LDFLAGS" \
  -o simv \
  -l compile.log

echo "=== 编译完成：simv ==="
EOFSH

chmod +x compile.sh
```

### 2.4 创建运行脚本
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim
cat > run.sh << 'EOFSH'
#!/bin/bash
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

source ../../config/env.sh

# 默认参数（根据阶段 0.2 填写）
ELF_FILE="${ELF_FILE:-~/buckyball/bb-tests/output/workloads/src/CTest/toy/toy-baremetal}"
RUN_TAG="${RUN_TAG:-$(date +%m%d_%H%M)}"
RESULT_DIR="${RESULT_DIR:-./results/$RUN_TAG}"

mkdir -p "$RESULT_DIR"

echo "=== 运行 gate-level simulation ==="
echo "ELF: $ELF_FILE"
echo "输出: $RESULT_DIR"

export LD_LIBRARY_PATH="~/buckyball/result/lib:~/buckyball/arch/thirdparty/chipyard/tools/DRAMSim2:${LD_LIBRARY_PATH:-}"

./simv \
  +elf="$ELF_FILE" \
  +saif="$RESULT_DIR/glsim.saif" \
  +vcd="$RESULT_DIR/glsim.vcd" \
  +reset_cycles=200 \
  +warmup_cycles=1000 \
  +permissive \
  -l "$RESULT_DIR/sim.log"

echo "=== 仿真完成 ==="
ls -lh "$RESULT_DIR"
EOFSH

chmod +x run.sh
```

---

## 阶段 3：编译与 debug（预估最耗时）

### 3.1 首次编译
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim
./compile.sh
```

**预期问题与解法**：

| 错误类型 | 可能原因 | 解决方案 |
|---------|---------|---------|
| `verilated.h: No such file` | DPI C++ 引用了 Verilator 头 | 改写 `monitor.cc` / `bdb_clk.cc`，去掉 Verilated 依赖 |
| `undefined reference to sim_exit` | `mmio.cc` 的 `sim_exit()` 未定义 | 改成 VCS 的 `$finish` 或自己实现 `void sim_exit(int code) { vpi_control(vpiFinish, code); }` |
| `libdramsim.so: cannot open` | 库路径错 | 检查 `~/buckyball/result/lib`，补 `-Wl,-rpath` |
| SRAM/std cell 模块重定义 | 某些文件重复 | 从 filelist 去重 |

**检查点**：`simv` 生成成功 → 进入 3.2

### 3.2 空跑测试（不加 ELF，只测 reset）
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim
mkdir -p results/dryrun

./simv +saif=results/dryrun/test.saif +vcd=results/dryrun/test.vcd \
  -l results/dryrun/test.log

# 检查 log
grep -E 'Error|Fatal|x.*propagat' results/dryrun/test.log
```

**预期结果**：
- ✅ 跑到超时 `$finish`，无 Fatal error
- ⚠️ 若大量 `x` 传播 → 加强 `+vcs+initreg+random`，或在 tb 里 force 关键 reset 信号
- ❌ 若立即 crash → DPI 实现有问题，回退到 stub DPI 先跳通

### 3.3 加载 ELF 实测
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim

# 使用阶段 0.2 确认的 ELF
export ELF_FILE=~/buckyball/bb-tests/output/.../toy-baremetal  # 替换成实际路径
./run.sh
```

**检查点**：
- `results/<RUN_TAG>/sim.log` 里看到 `SCU exit hart_id=0 code=0`（正常退出）
- `glsim.saif` 文件生成，大小 > 1MB
- `glsim.vcd` 文件生成（可能很大，10GB+）

---

## 阶段 4：PTPX 读取 SAIF 并分析功耗

### 4.1 复制 SAIF 到 PTPX 工作区
```bash
cd /home/sjm/tapeout
RUN_TAG=$(date +%m%d_%H%M)_glsim

mkdir -p 3_POWER/waveform/$RUN_TAG
cp 1_PRESIM/glsim/results/*/glsim.saif 3_POWER/waveform/$RUN_TAG/
cp 1_PRESIM/glsim/results/*/glsim.vcd 3_POWER/waveform/$RUN_TAG/  # 可选，仅 debug 用
```

### 4.2 运行 PTPX（SAIF 模式）
```bash
cd /home/sjm/tapeout/3_POWER

export PTPX_NETLIST_FILE=/home/sjm/tapeout/3_POWER/netlist/ChipTop.v
export PTPX_SDC_FILE=/home/sjm/tapeout/3_POWER/netlist/ChipTop.sdc
export PTPX_ACTIVITY_FILE=/home/sjm/tapeout/3_POWER/waveform/${RUN_TAG}/glsim.saif
export PTPX_ACTIVITY_FORMAT=saif
export PTPX_STRIP_PATH=TOP/BBSimHarness/chiptop0

./run_ptpx
```

**检查点**：
```bash
# 查看 annotation coverage
grep -E 'Number of annotated|coverage' logs/ptpx_*.log

# 预期：
# Number of annotated nets = XXXXXX (>80%)
# Number of fully annotated leaf cells = XXXXXX (>60%)
```

### 4.3 对比 RTL vs gate-level 功耗
```bash
cd /home/sjm/tapeout/3_POWER/rpt

# 之前 RTL 的 14% 覆盖率结果
cat 0606_0128/ChipTop_power_total.rpt | grep -A5 'Total Power'

# 新的 gate-level 结果
cat ${RUN_TAG}/ChipTop_power_total.rpt | grep -A5 'Total Power'
```

**期望结果**：
- gate-level 动态功耗 >> RTL 的近 0 值
- leakage 基本持平（与工艺/面积相关，不受 activity 影响）
- switching power / internal power 明显增大

---

## 阶段 5：优化与迭代

### 5.1 若 SAIF coverage 仍不理想（<60%）
**原因排查**：
1. `$set_toggle_region` 范围太小 → 扩到 `BBSimHarness`（会包含 harness 开销）
2. warmup 不够 → 增加 `+warmup_cycles=5000`
3. workload 太短 → 换更长的测试用例

### 5.2 若需要 SDF back-annotation（更精确时序）
```bash
# 1. DC 导出 SDF
cd /home/sjm/tapeout/2_SYN
# （假设已有 write_sdf 脚本，或手动在 dc_shell 里 write_sdf）

# 2. VCS 编译时加 SDF
cd /home/sjm/tapeout/1_PRESIM/glsim
# 在 compile.sh 加 -sdf_cmd_file=sdf.cmd

cat > sdf.cmd << EOF
assign ChipTop /home/sjm/tapeout/2_SYN/outputs/<run>/ChipTop.sdf
EOF

./compile.sh
./run.sh
```

### 5.3 多 workload 批量跑
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim

for elf in ~/buckyball/bb-tests/output/workloads/src/CTest/*/; do
  export ELF_FILE="$elf/$(basename $elf)-baremetal"
  export RUN_TAG="$(date +%m%d_%H%M)_$(basename $elf)"
  ./run.sh
done

# 合并多个 SAIF（若需平均功耗）
# 或分别喂给 PTPX，对比不同场景功耗
```

---

## 阶段 6：交付物与文档

### 6.1 整理目录结构
```
/home/sjm/tapeout/
├── 1_PRESIM/glsim/           ← gate-level sim 工作区
│   ├── filelist.f
│   ├── tb_glsim.sv
│   ├── compile.sh / run.sh
│   ├── simv (可执行文件)
│   ├── models/std_cell/      ← 解包的 std cell 模型
│   ├── results/              ← 各次仿真输出 SAIF/VCD/log
│   └── README.md             ← 使用说明
└── 3_POWER/
    ├── waveform/<run>_glsim/ ← gate-level SAIF/VCD
    └── rpt/<run>_glsim/      ← PTPX 功耗报告
```

### 6.2 写 README
```bash
cd /home/sjm/tapeout/1_PRESIM/glsim
cat > README.md << 'EOF'
# Gate-Level Simulation for Power Analysis

## 快速开始
1. 编译：`./compile.sh`
2. 运行：`export ELF_FILE=<path>; ./run.sh`
3. 查看结果：`ls -lh results/<RUN_TAG>/`
4. 喂给 PTPX：`cp results/<RUN_TAG>/glsim.saif ../../3_POWER/waveform/`

## 参数调整
- `+reset_cycles=N`：reset 周期数（默认 200）
- `+warmup_cycles=N`：预热周期数（默认 1000）
- `+saif=file`：SAIF 输出路径
- `+vcd=file`：VCD 输出路径

## 故障排查
- 编译失败 → 检查 `compile.log`，确认 DPI C++ 无 Verilator 依赖
- 仿真卡住 → 增加 `+reset_cycles`，或检查 ELF 加载是否成功
- SAIF coverage 低 → 增加 `+warmup_cycles`，或换更长 workload

## 依赖
- VCS W-2024.09+
- libdramsim (~/buckyball/result/lib)
- libelf, readline
- TSMC std cell + SRAM Verilog 模型
EOF
```

---

## 时间预估与风险

| 阶段 | 预估工时 | 风险等级 | 阻塞因素 |
|------|---------|---------|---------|
| 0. 前置核对 | 0.5h | 低 | DPI 代码有 Verilator 硬依赖 |
| 1. 准备模型文件 | 1h | 低 | 文件路径错误 |
| 2. 编写仿真文件 | 1h | 低 | 脚本语法错误 |
| 3. 编译与 debug | **4-8h** | **高** | DPI 重新编译、`x` 传播、库链接 |
| 4. PTPX 分析 | 0.5h | 低 | SAIF 格式兼容性 |
| 5. 优化迭代 | 2-4h | 中 | coverage 仍不理想 |
| **总计** | **9-15h** | | |

**最大风险点**：阶段 3.1 首次编译，若 DPI C++ 大量依赖 Verilator 内部 API，需改写 monitor.cc / mmio.cc，可能额外增加 4-6h。

**降低风险策略**：
1. 阶段 0.1 严格核对，若发现 Verilated 依赖多，**先用 stub DPI 跳通流程**（空内存/假 UART），验证网表能跑，再接真 DPI。
2. 准备回退方案：若 VCS DPI 路径不通，降级到 **Verilator gate-level**（虽然慢，但兼容性更好）。

---

## 成功标准
- ✅ VCS `simv` 编译通过
- ✅ gate-level sim 跑完 workload，正常退出（`SCU exit code=0`）
- ✅ SAIF 文件生成，大小 > 1MB
- ✅ PTPX 读 SAIF 后 `Number of annotated nets` **> 80%**
- ✅ 动态功耗（switching + internal）**> 1mW**（不再接近 0）
- ✅ 与 RTL sim 的功能行为一致（通过 log 对比 hart exit code）

---

## 下一步行动
1. **立即执行**：阶段 0.1 核对 DPI 依赖 → 决定是走真 DPI 还是先 stub
2. **并行准备**：阶段 1 准备模型文件（可在核对同时进行）
3. **关键决策点**：阶段 3.1 编译结果 → 若失败超过 2 次，启动回退方案

---

## 附录：常用命令速查

```bash
# 重新编译
cd /home/sjm/tapeout/1_PRESIM/glsim && ./compile.sh

# 运行指定 ELF
export ELF_FILE=<path> && ./run.sh

# 查看最新仿真 log
tail -f results/$(ls -t results/ | head -1)/sim.log

# 检查 SAIF 内容
head -50 results/*/glsim.saif

# PTPX 快速重跑
cd ../../3_POWER && ./run_ptpx

# 对比新旧功耗
grep 'Total Power' rpt/0606_0128/ChipTop_power_total.rpt
grep 'Total Power' rpt/$(ls -t rpt/ | head -1)/ChipTop_power_total.rpt
```

---

**计划版本**：v1.0  
**创建时间**：2026-06-06  
**预期完成**：2026-06-07（若无重大阻塞）