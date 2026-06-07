`timescale 1ns/1ps

module tb_glsim_mixed;
  logic clock;
  logic reset;

  longint unsigned cycle;
  longint unsigned max_cycles;
  longint unsigned progress_interval;
  longint unsigned reset_hold_ticks;
  string vcd_file;
  string saif_file;
  bit dump_vcd;
  bit dump_saif;
  bit bb_saif_window;
  bit saif_active;
  bit saif_done;
  logic saif_prev_busy;
  bit debug_clocks;
  string retire_log_file;
  string scu_log_file;
  string dcache_log_file;
  string tile_tl_log_file;
  string rocc_log_file;
  string reset_log_file;
  int retire_fd;
  int scu_fd;
  int dcache_fd;
  int tile_tl_fd;
  int rocc_fd;
  int reset_fd;
  int reset_tile_edges;

  localparam real HARNESS_HALF_PERIOD_NS = 0.001;

  BBSimHarness dut (
    .clock(clock),
    .reset(reset)
  );

  function automatic longint unsigned plusarg_u64(input string name,
                                                  input longint unsigned dflt);
    longint unsigned value;
    if ($value$plusargs({name, "=%d"}, value))
      return value;
    return dflt;
  endfunction

  function automatic string plusarg_string(input string name,
                                           input string dflt);
    string value;
    if ($value$plusargs({name, "=%s"}, value))
      return value;
    return dflt;
  endfunction

  task automatic dump_wave_setup;
    vcd_file = plusarg_string("vcd", "glsim_mixed.vcd");
    saif_file = plusarg_string("saif", "glsim_mixed.saif");
    dump_vcd = !$test$plusargs("no_vcd");
    dump_saif = !$test$plusargs("no_saif");
    bb_saif_window = $test$plusargs("BB_SAIF");
    saif_active = 1'b0;
    saif_done = 1'b0;
    saif_prev_busy = 1'b0;

    if (dump_vcd) begin
      $dumpfile(vcd_file);
      $dumpvars(0, tb_glsim_mixed);
      $display("[tb] raw VCD dump enabled: %s", vcd_file);
    end

    if (dump_saif) begin
      $set_gate_level_monitoring("rtl_on");
      $set_toggle_region(tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0);
      if (bb_saif_window) begin
        $display("[tb] BB_SAIF armed: start on accelerator io.cmd.valid, stop on io.busy 1->0: %s",
                 saif_file);
      end else begin
        $toggle_start();
        saif_active = 1'b1;
        $display("[tb] SAIF toggle capture enabled: %s", saif_file);
      end
    end
  endtask

  task automatic saif_start(input string reason);
    if (dump_saif && bb_saif_window && !saif_active && !saif_done) begin
      $toggle_start();
      saif_active = 1'b1;
      $display("[tb] BB_SAIF started (%s): %s", reason, saif_file);
    end
  endtask

  task automatic saif_stop_and_report(input string reason);
    if (dump_saif && saif_active) begin
      $toggle_stop();
      saif_active = 1'b0;
      saif_done = 1'b1;
      $toggle_report(saif_file, 1.0e-9, tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0);
      $display("[tb] SAIF written (%s): %s", reason, saif_file);
    end
  endtask

  task automatic dump_wave_finish;
    if (dump_saif) begin
      if (saif_active) begin
        saif_stop_and_report("simulation finish");
      end else if (bb_saif_window && !saif_done) begin
        $display("[tb] BB_SAIF window never completed; no SAIF written: %s", saif_file);
      end
    end
  endtask

  task automatic trace_setup;
    if ($value$plusargs("retire_log=%s", retire_log_file)) begin
      retire_fd = $fopen(retire_log_file, "w");
      if (retire_fd == 0)
        $display("[tb] warning: failed to open retire trace: %s", retire_log_file);
      else
        $display("[tb] retire trace enabled: %s", retire_log_file);
    end

    if ($value$plusargs("scu_log=%s", scu_log_file)) begin
      scu_fd = $fopen(scu_log_file, "w");
      if (scu_fd == 0)
        $display("[tb] warning: failed to open SCU trace: %s", scu_log_file);
      else
        $display("[tb] SCU trace enabled: %s", scu_log_file);
    end

    if ($value$plusargs("dcache_log=%s", dcache_log_file)) begin
      dcache_fd = $fopen(dcache_log_file, "w");
      if (dcache_fd == 0)
        $display("[tb] warning: failed to open D-cache trace: %s", dcache_log_file);
      else
        $display("[tb] D-cache trace enabled: %s", dcache_log_file);
    end

    if ($value$plusargs("tile_tl_log=%s", tile_tl_log_file)) begin
      tile_tl_fd = $fopen(tile_tl_log_file, "w");
      if (tile_tl_fd == 0)
        $display("[tb] warning: failed to open tile TL trace: %s", tile_tl_log_file);
      else
        $display("[tb] tile TL trace enabled: %s", tile_tl_log_file);
    end

    if ($value$plusargs("rocc_log=%s", rocc_log_file)) begin
      rocc_fd = $fopen(rocc_log_file, "w");
      if (rocc_fd == 0)
        $display("[tb] warning: failed to open RoCC trace: %s", rocc_log_file);
      else
        $display("[tb] RoCC trace enabled: %s", rocc_log_file);
    end

    if ($value$plusargs("reset_log=%s", reset_log_file)) begin
      reset_fd = $fopen(reset_log_file, "w");
      if (reset_fd == 0)
        $display("[tb] warning: failed to open reset trace: %s", reset_log_file);
      else
        $display("[tb] reset trace enabled: %s", reset_log_file);
    end
  endtask

  task automatic verilator_init_sequence;
    automatic int hold_ticks;
    hold_ticks = int'(reset_hold_ticks);
    if (hold_ticks < 1)
      hold_ticks = 1;

    // Match arch/src/csrc/src/main.cc sim_init(): evaluate once at
    // reset=1/clock=0 before the reset-qualified posedge.
    reset = 1'b1;
    clock = 1'b0;
    #(HARNESS_HALF_PERIOD_NS);

    repeat (hold_ticks) begin
      clock = 1'b1;
      #(HARNESS_HALF_PERIOD_NS);
      clock = 1'b0;
      #(HARNESS_HALF_PERIOD_NS);
    end

    reset = 1'b0;
    #(HARNESS_HALF_PERIOD_NS);
  endtask

  task automatic verilator_cycle_step;
    // Mirrors ball_exec_once(): posedge/eval/dump, then negedge/eval/dump.
    clock = 1'b1;
    #(HARNESS_HALF_PERIOD_NS);
    cycle++;
    if (progress_interval != 0 && (cycle % progress_interval) == 0) begin
      $display("[tb] progress cycle=%0d / %0d time=%0t", cycle, max_cycles, $time);
    end

    clock = 1'b0;
    #(HARNESS_HALF_PERIOD_NS);
  endtask

  initial begin
    cycle = 0;
    max_cycles = plusarg_u64("cycles", 100000);
    progress_interval = plusarg_u64("progress", 1000);
    reset_hold_ticks = plusarg_u64("reset_hold_ticks", 1);
    debug_clocks = $test$plusargs("debug_clocks");

    $display("[tb] Buckyball mixed GLS start");
    $display("[tb] max_cycles=%0d progress_interval=%0d", max_cycles, progress_interval);
    $display("[tb] reset_hold_ticks=%0d", reset_hold_ticks);
    if (!$test$plusargs("elf"))
      $display("[tb] warning: no +elf=<path> was provided; DRAM starts zero-filled");

    dump_wave_setup();
    trace_setup();
    verilator_init_sequence();

    while (cycle < max_cycles) begin
      verilator_cycle_step();
      if (debug_clocks && (progress_interval == 0 || (cycle % progress_interval) == 0)) begin
        $display("[tb] debug dram_clk=%b dram_reset=%b dram_initialized=%b chip_reset=%b",
                 tb_glsim_mixed.dut._chiptop0_axi4_mem_0_clock,
                 tb_glsim_mixed.dut._harnessBinderReset_catcher_io_sync_reset,
                 tb_glsim_mixed.dut.bbsimdram.initialized,
                 tb_glsim_mixed.dut.reset);
      end
    end

    $display("[tb] reached +cycles=%0d", max_cycles);
    dump_wave_finish();
    $finish;
  end

  final begin
    if (retire_fd != 0)
      $fclose(retire_fd);
    if (scu_fd != 0)
      $fclose(scu_fd);
    if (dcache_fd != 0)
      $fclose(dcache_fd);
    if (tile_tl_fd != 0)
      $fclose(tile_tl_fd);
    if (rocc_fd != 0)
      $fclose(rocc_fd);
    if (reset_fd != 0)
      $fclose(reset_fd);
    $display("[tb] final cycle=%0d time=%0t", cycle, $time);
  end

  always @(posedge tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.clock) begin
    if (dump_saif && bb_saif_window && !saif_done) begin
      automatic logic tile_reset =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.reset;
      automatic logic cmd_valid =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_valid;
      automatic logic busy =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._accelerators_0_io_busy;

      if (tile_reset) begin
        saif_prev_busy <= 1'b0;
      end else begin
        if (cmd_valid === 1'b1)
          saif_start("io.cmd.valid");

        if (saif_active && saif_prev_busy === 1'b1 && busy === 1'b0)
          saif_stop_and_report("io.busy 1->0");

        if (!$isunknown(busy))
          saif_prev_busy <= busy;
      end
    end
  end

  always @(posedge tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.clock) begin
    if (reset_fd != 0 && reset_tile_edges < 256) begin
      reset_tile_edges++;
      $fwrite(reset_fd,
              "time=%0t tb_cycle=%0d tb_reset=%b dut_reset=%b tile_reset=%b core_reset=%b accel_reset=%b mem_reset=%b ptrs=%b/%b full=%b deq_valid=%b cf_valid=%b\n",
              $time,
              cycle,
              reset,
              tb_glsim_mixed.dut.reset,
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.reset,
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0.reset,
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.reset,
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.reset,
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memRs.fifo.enq_ptr_value,
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memRs.fifo.deq_ptr_value,
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memRs.fifo.maybe_full,
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memRs.n_fifo_io_deq_valid,
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.n_memRs_io_issue_o_cf_valid);
    end
  end

  always @(posedge tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0.clock) begin
    if (retire_fd != 0
        && !tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0.reset
        && tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0._csr_io_trace_0_valid) begin
      $fwrite(retire_fd,
              "time=%0t tb_cycle=%0d core_time=%0d valid=%0d pc=%016h inst=%08h exception=%0d\n",
              $time,
              cycle,
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0._csr_io_time[31:0],
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0._csr_io_trace_0_valid
                & ~tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0._csr_io_trace_0_exception,
              {{24{tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0._csr_io_trace_0_iaddr[39]}},
               tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0._csr_io_trace_0_iaddr},
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0._csr_io_trace_0_insn,
              tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0._csr_io_trace_0_exception);
    end
  end

  always @(posedge tb_glsim_mixed.dut.chiptop0.system._cbus_auto_fixedClockNode_anon_out_4_clock) begin
    if (scu_fd != 0
        && tb_glsim_mixed.dut.chiptop0.system._scu_domain_auto_scu_in_a_ready
        && tb_glsim_mixed.dut.chiptop0.system._cbus_auto_coupler_to_scu_fragmenter_anon_out_a_valid) begin
      $fwrite(scu_fd,
              "time=%0t tb_cycle=%0d opcode=%0d size=%0d source=%0d address=%08h mask=%02h data=%016h corrupt=%0d\n",
              $time,
              cycle,
              tb_glsim_mixed.dut.chiptop0.system._cbus_auto_coupler_to_scu_fragmenter_anon_out_a_bits_opcode,
              tb_glsim_mixed.dut.chiptop0.system._cbus_auto_coupler_to_scu_fragmenter_anon_out_a_bits_size,
              tb_glsim_mixed.dut.chiptop0.system._cbus_auto_coupler_to_scu_fragmenter_anon_out_a_bits_source,
              tb_glsim_mixed.dut.chiptop0.system._cbus_auto_coupler_to_scu_fragmenter_anon_out_a_bits_address,
              tb_glsim_mixed.dut.chiptop0.system._cbus_auto_coupler_to_scu_fragmenter_anon_out_a_bits_mask,
              tb_glsim_mixed.dut.chiptop0.system._cbus_auto_coupler_to_scu_fragmenter_anon_out_a_bits_data,
              tb_glsim_mixed.dut.chiptop0.system._cbus_auto_coupler_to_scu_fragmenter_anon_out_a_bits_corrupt);
    end
  end

  always @(posedge tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.clock) begin
    if (rocc_fd != 0) begin
      automatic logic tile_reset =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.reset;
      automatic logic cmd_valid =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_valid;
      automatic logic cmd_ready =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._accelerators_0_io_cmd_ready;
      automatic logic busy =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._accelerators_0_io_busy;
	      automatic logic interrupt =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._accelerators_0_io_interrupt;
	      automatic logic rocc_blocked =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.cores_0.rocc_blocked;
	      automatic logic sched_decode_ready =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.io_decode_cmd_i_ready;
	      automatic logic sched_alloc_ready =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.n_rob_io_alloc_ready;
	      automatic logic sched_alloc_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.n_0_net_;
	      automatic logic sched_issue_ready =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.n_1_net_;
	      automatic logic sched_issue_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.n_rob_io_issue_valid;
	      automatic logic sched_empty =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.n_rob_io_empty;
	      automatic logic sched_full =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.n_rob_io_full;
	      automatic logic sched_fence =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.fenceActive;
	      automatic logic sched_barrier_rob =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.barrierWaitROB;
	      automatic logic sched_barrier_release =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.n170;
	      automatic logic sched_complete_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.n4;
	      automatic logic sched_complete_is_sub =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.frontend.scheduler.n_completeArb_io_out_bits_is_sub;
	      automatic logic ball_issue_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.n_frontend_io_ball_issue_o_valid;
	      automatic logic ball_issue_ready =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.n_ballDomain_global_issue_i_ready;
	      automatic logic ball_complete_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.n_ballDomain_global_complete_o_valid;
	      automatic logic mem_issue_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.n_frontend_io_mem_issue_o_valid;
	      automatic logic mem_issue_ready =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.n_memDomain_io_global_issue_i_ready;
	      automatic logic mem_complete_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.n_memDomain_io_global_complete_o_valid;
	      automatic logic mem_ld_resp_ready =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.n_memRs_io_commit_i_ld_ready;
	      automatic logic mem_ld_resp_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.n_memLoader_io_cmdResp_valid;
	      automatic logic mem_st_resp_ready =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.n_memRs_io_commit_i_st_ready;
	      automatic logic mem_st_resp_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.n_memStorer_io_cmdResp_valid;
	      automatic logic mem_cf_resp_ready =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.n_memRs_io_commit_i_cf_ready;
	      automatic logic mem_cf_resp_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.n_configer_io_cmdResp_valid;
	      automatic logic mem_cf_req_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.n_memRs_io_issue_o_cf_valid;
	      automatic logic mem_cf_req_mmio_set =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.n_memRs_io_issue_o_cf_bits_cmd_is_mmio_set;
	      automatic logic mem_cf_n134 =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.configer.n134;
	      automatic logic mem_cf_n181 =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.configer.n181;
	      automatic logic mem_cf_n180 =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.configer.n180;
	      automatic logic mem_cf_n152 =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.configer.n152;
	      automatic logic mem_rs_fifo_deq_ready =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memRs.n_0_net_;
	      automatic logic mem_rs_fifo_deq_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memRs.n_fifo_io_deq_valid;
	      automatic logic mem_rs_fifo_deq_config =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memRs.n_fifo_io_deq_bits_cmd_is_config;
	      automatic logic mem_rs_fifo_deq_mmio_set =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memRs.io_issue_o_cf_bits_cmd_is_mmio_set;
	      automatic logic [1:0] mem_rs_fifo_enq_ptr =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memRs.fifo.enq_ptr_value;
	      automatic logic [1:0] mem_rs_fifo_deq_ptr =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memRs.fifo.deq_ptr_value;
	      automatic logic mem_rs_fifo_maybe_full =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memRs.fifo.maybe_full;
	      automatic logic [2:0] mem_ld_state =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memLoader.state;
	      automatic logic [2:0] mem_st_state =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.memStorer.state;
	      automatic logic [1:0] mem_cf_state =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.memDomain.frontend.configer.state;
	      automatic logic gp_issue_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.n_frontend_io_gp_issue_o_valid;
	      automatic logic gp_issue_ready =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.n_gpDomain_io_global_issue_i_ready;
	      automatic logic gp_complete_valid =
	        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0.n_gpDomain_io_global_complete_o_valid;
	      automatic bit has_x =
	        $isunknown(cmd_valid)
	        || $isunknown(cmd_ready)
	        || $isunknown(busy)
	        || $isunknown(interrupt)
	        || $isunknown(rocc_blocked)
	        || $isunknown(sched_decode_ready)
	        || $isunknown(sched_alloc_ready)
	        || $isunknown(sched_alloc_valid)
	        || $isunknown(sched_issue_ready)
	        || $isunknown(sched_issue_valid)
	        || $isunknown(sched_empty)
	        || $isunknown(sched_full)
	        || $isunknown(sched_fence)
	        || $isunknown(sched_barrier_rob)
	        || $isunknown(sched_barrier_release)
	        || $isunknown(sched_complete_valid)
	        || $isunknown(sched_complete_is_sub)
	        || $isunknown(ball_issue_valid)
	        || $isunknown(ball_issue_ready)
	        || $isunknown(ball_complete_valid)
	        || $isunknown(mem_issue_valid)
	        || $isunknown(mem_issue_ready)
	        || $isunknown(mem_complete_valid)
	        || $isunknown(mem_ld_resp_ready)
	        || $isunknown(mem_ld_resp_valid)
	        || $isunknown(mem_st_resp_ready)
	        || $isunknown(mem_st_resp_valid)
	        || $isunknown(mem_cf_resp_ready)
	        || $isunknown(mem_cf_resp_valid)
	        || $isunknown(mem_cf_req_valid)
	        || $isunknown(mem_cf_req_mmio_set)
	        || $isunknown(mem_cf_n134)
	        || $isunknown(mem_cf_n181)
	        || $isunknown(mem_cf_n180)
	        || $isunknown(mem_cf_n152)
	        || $isunknown(mem_rs_fifo_deq_ready)
	        || $isunknown(mem_rs_fifo_deq_valid)
	        || $isunknown(mem_rs_fifo_deq_config)
	        || $isunknown(mem_rs_fifo_deq_mmio_set)
	        || $isunknown(mem_rs_fifo_enq_ptr)
	        || $isunknown(mem_rs_fifo_deq_ptr)
	        || $isunknown(mem_rs_fifo_maybe_full)
	        || $isunknown(mem_ld_state)
	        || $isunknown(mem_st_state)
	        || $isunknown(mem_cf_state)
	        || $isunknown(gp_issue_valid)
	        || $isunknown(gp_issue_ready)
	        || $isunknown(gp_complete_valid)
	        || $isunknown(tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_bits_pc)
	        || $isunknown(tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_bits_funct)
	        || $isunknown(tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_bits_rs1Data)
	        || $isunknown(tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_bits_rs2Data);
      automatic bit interesting =
        cmd_valid
        || busy
        || interrupt
        || rocc_blocked
        || has_x;

	      if (!tile_reset && interesting) begin
	        $fwrite(rocc_fd,
	                "time=%0t tb_cycle=%0d cmd=%b/%b pc=%016h funct=%02h rs1=%0d rs2=%0d opcode=%02h rs1Data=%016h rs2Data=%016h busy=%b interrupt=%b rocc_blocked=%b sched_dec=%b sched_alloc=%b/%b sched_issue=%b/%b sched_empty=%b sched_full=%b fence=%b barrier=%b/%b complete=%b/%b ball=%b/%b/%b mem=%b/%b/%b mem_resp(ld/st/cf)=%b/%b/%b ready=%b/%b/%b cf_req=%b/%b cf_int(n134/n181/n180/n152)=%b/%b/%b/%b memrs_fifo(deq_r/v/cfg/mmio,ptrs,full)=%b/%b/%b/%b,%b/%b,%b mem_state(ld/st/cf)=%b/%b/%b gp=%b/%b/%b has_x=%0d\n",
	                $time,
	                cycle,
	                cmd_valid,
                cmd_ready,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_bits_pc,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_bits_funct,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_bits_rs1,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_bits_rs2,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_bits_opcode,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_bits_rs1Data,
	                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_rocc_cmd_bits_rs2Data,
	                busy,
	                interrupt,
	                rocc_blocked,
	                sched_decode_ready,
	                sched_alloc_valid,
	                sched_alloc_ready,
	                sched_issue_valid,
	                sched_issue_ready,
	                sched_empty,
	                sched_full,
	                sched_fence,
	                sched_barrier_rob,
	                sched_barrier_release,
	                sched_complete_valid,
	                sched_complete_is_sub,
	                ball_issue_valid,
	                ball_issue_ready,
	                ball_complete_valid,
	                mem_issue_valid,
	                mem_issue_ready,
	                mem_complete_valid,
	                mem_ld_resp_valid,
	                mem_st_resp_valid,
	                mem_cf_resp_valid,
	                mem_ld_resp_ready,
	                mem_st_resp_ready,
	                mem_cf_resp_ready,
	                mem_cf_req_valid,
	                mem_cf_req_mmio_set,
	                mem_cf_n134,
	                mem_cf_n181,
	                mem_cf_n180,
	                mem_cf_n152,
	                mem_rs_fifo_deq_ready,
	                mem_rs_fifo_deq_valid,
	                mem_rs_fifo_deq_config,
	                mem_rs_fifo_deq_mmio_set,
	                mem_rs_fifo_enq_ptr,
	                mem_rs_fifo_deq_ptr,
	                mem_rs_fifo_maybe_full,
	                mem_ld_state,
	                mem_st_state,
	                mem_cf_state,
	                gp_issue_valid,
	                gp_issue_ready,
	                gp_complete_valid,
	                has_x);
	      end
    end
  end

  always @(posedge tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.clock) begin
    if (dcache_fd != 0) begin
      automatic bit core_req_fire =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_dmem_req_valid
        && tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcacheArb_io_requestor_1_req_ready;
      automatic bit arb_req_fire =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcacheArb_io_mem_req_valid
        && tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_io_cpu_req_ready;
      automatic bit tl_a_fire =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_auto_out_a_valid
        && tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._tlMasterXbar_auto_anon_in_0_a_ready;
      automatic bit tl_d_fire =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._tlMasterXbar_auto_anon_in_0_d_valid
        && tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_auto_out_d_ready;
      automatic bit interesting =
        core_req_fire
        || arb_req_fire
        || tl_a_fire
        || tl_d_fire
        || tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcacheArb_io_requestor_1_s2_nack
        || tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_io_cpu_s2_nack
        || tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcacheArb_io_requestor_1_resp_valid
        || tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_io_cpu_resp_valid;

      if (interesting) begin
        $fwrite(dcache_fd,
                "time=%0t tb_cycle=%0d core_req=%0d/%0d addr=%010h cmd=%0d size=%0d kill=%0d core_nack=%0d core_resp=%0d arb_req=%0d/%0d addr=%010h cmd=%0d size=%0d dcache_nack=%0d dcache_resp=%0d tl_a=%0d/%0d op=%0d addr=%08h src=%0d tl_d=%0d/%0d op=%0d src=%0d sink=%0d\n",
                $time,
                cycle,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_dmem_req_valid,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcacheArb_io_requestor_1_req_ready,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_dmem_req_bits_addr,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_dmem_req_bits_cmd,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_dmem_req_bits_size,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._cores_0_io_dmem_s1_kill,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcacheArb_io_requestor_1_s2_nack,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcacheArb_io_requestor_1_resp_valid,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcacheArb_io_mem_req_valid,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_io_cpu_req_ready,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcacheArb_io_mem_req_bits_addr,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcacheArb_io_mem_req_bits_cmd,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcacheArb_io_mem_req_bits_size,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_io_cpu_s2_nack,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_io_cpu_resp_valid,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_auto_out_a_valid,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._tlMasterXbar_auto_anon_in_0_a_ready,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_auto_out_a_bits_opcode,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_auto_out_a_bits_address,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_auto_out_a_bits_source,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._tlMasterXbar_auto_anon_in_0_d_valid,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._dcache_auto_out_d_ready,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._tlMasterXbar_auto_anon_in_0_d_bits_opcode,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._tlMasterXbar_auto_anon_in_0_d_bits_source,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile._tlMasterXbar_auto_anon_in_0_d_bits_sink);
      end
    end
  end

  always @(posedge tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.clock) begin
    if (tile_tl_fd != 0) begin
      automatic bit bbtile_a_fire =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._element_reset_domain_bbtile_auto_buffer_out_1_a_valid
        && tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._buffer_auto_in_1_a_ready;
      automatic bit tprci_a_fire =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_a_valid
        && tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_a_ready;
      automatic bit bbtile_d_fire =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._buffer_auto_in_1_d_valid
        && tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._element_reset_domain_bbtile_auto_buffer_out_1_d_ready;
      automatic bit tprci_d_fire =
        tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_d_valid
        && tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_d_ready;
      automatic bit interesting =
        bbtile_a_fire
        || tprci_a_fire
        || bbtile_d_fire
        || tprci_d_fire
        || tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._element_reset_domain_bbtile_auto_buffer_out_1_a_valid
        || tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_a_valid;

      if (interesting) begin
        $fwrite(tile_tl_fd,
                "time=%0t tb_cycle=%0d domain=tile bbtile_a=%0d/%0d op=%0d size=%0d src=%0d addr=%08h tprci_a=%0d/%0d op=%0d size=%0d src=%0d addr=%08h bbtile_d=%0d/%0d op=%0d src=%0d sink=%0d tprci_d=%0d/%0d op=%0d src=%0d sink=%0d\n",
                $time,
                cycle,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._element_reset_domain_bbtile_auto_buffer_out_1_a_valid,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._buffer_auto_in_1_a_ready,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._element_reset_domain_bbtile_auto_buffer_out_1_a_bits_opcode,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._element_reset_domain_bbtile_auto_buffer_out_1_a_bits_size,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._element_reset_domain_bbtile_auto_buffer_out_1_a_bits_source,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._element_reset_domain_bbtile_auto_buffer_out_1_a_bits_address,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_a_valid,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_a_ready,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_a_bits_opcode,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_a_bits_size,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_a_bits_source,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_a_bits_address,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._buffer_auto_in_1_d_valid,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._element_reset_domain_bbtile_auto_buffer_out_1_d_ready,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._buffer_auto_in_1_d_bits_opcode,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._buffer_auto_in_1_d_bits_source,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain._buffer_auto_in_1_d_bits_sink,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_d_valid,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_d_ready,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_d_bits_opcode,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_d_bits_source,
                tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.auto_tl_master_clock_xing_out_1_d_bits_sink);
      end
    end
  end

  always @(posedge tb_glsim_mixed.dut.chiptop0.system._sbus_auto_fixedClockNode_anon_out_0_clock) begin
    if (tile_tl_fd != 0) begin
      automatic bit sbus_in_a_fire =
        tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_1_a_valid
        && tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_from_bbtile_tl_master_clock_xing_in_1_a_ready;
      automatic bit sbus_in_d_fire =
        tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_from_bbtile_tl_master_clock_xing_in_1_d_valid
        && tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_1_d_ready;
      automatic bit coh_out_a_fire =
        tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_to_bus_named_coh_widget_anon_out_a_valid
        && tb_glsim_mixed.dut.chiptop0.system._coh_wrapper_auto_coherent_jbar_anon_in_a_ready;
      automatic bit sbus_in0_a_fire =
        tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_0_a_valid
        && tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_from_bbtile_tl_master_clock_xing_in_0_a_ready;
      automatic bit sbus_in0_a_x =
        $isunknown(tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_0_a_valid)
        || $isunknown(tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_0_a_bits_opcode)
        || $isunknown(tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_0_a_bits_address);
      automatic bit interesting =
        sbus_in_a_fire
        || sbus_in_d_fire
        || coh_out_a_fire
        || sbus_in0_a_fire
        || sbus_in0_a_x
        || tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_1_a_valid
        || tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_to_bus_named_coh_widget_anon_out_a_valid;

      if (interesting) begin
        $fwrite(tile_tl_fd,
                "time=%0t tb_cycle=%0d domain=sbus in1_a=%b/%b op=%0d size=%0d src=%0d addr=%08h in1_d=%b/%b op=%0d src=%0d sink=%0d in0_a=%b/%b op=%b size=%b src=%b addr=%h coh_a=%b/%b op=%b size=%b src=%b addr=%h\n",
                $time,
                cycle,
                tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_1_a_valid,
                tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_from_bbtile_tl_master_clock_xing_in_1_a_ready,
                tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_1_a_bits_opcode,
                tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_1_a_bits_size,
                tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_1_a_bits_source,
                tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_1_a_bits_address,
                tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_from_bbtile_tl_master_clock_xing_in_1_d_valid,
                tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_1_d_ready,
                tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_from_bbtile_tl_master_clock_xing_in_1_d_bits_opcode,
                tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_from_bbtile_tl_master_clock_xing_in_1_d_bits_source,
                tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_from_bbtile_tl_master_clock_xing_in_1_d_bits_sink,
                tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_0_a_valid,
                tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_from_bbtile_tl_master_clock_xing_in_0_a_ready,
                tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_0_a_bits_opcode,
                tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_0_a_bits_size,
                tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_0_a_bits_source,
                tb_glsim_mixed.dut.chiptop0.system._tile_prci_domain_auto_tl_master_clock_xing_out_0_a_bits_address,
                tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_to_bus_named_coh_widget_anon_out_a_valid,
                tb_glsim_mixed.dut.chiptop0.system._coh_wrapper_auto_coherent_jbar_anon_in_a_ready,
                tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_to_bus_named_coh_widget_anon_out_a_bits_opcode,
                tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_to_bus_named_coh_widget_anon_out_a_bits_size,
                tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_to_bus_named_coh_widget_anon_out_a_bits_source,
                tb_glsim_mixed.dut.chiptop0.system._sbus_auto_coupler_to_bus_named_coh_widget_anon_out_a_bits_address);
      end
    end
  end
endmodule
