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

    $display("[tb] Buckyball mixed GLS start");
    $display("[tb] max_cycles=%0d progress_interval=%0d", max_cycles, progress_interval);
    $display("[tb] reset_hold_ticks=%0d", reset_hold_ticks);
    if (!$test$plusargs("elf"))
      $display("[tb] warning: no +elf=<path> was provided; DRAM starts zero-filled");

    dump_wave_setup();
    verilator_init_sequence();

    while (cycle < max_cycles) begin
      verilator_cycle_step();
    end

    $display("[tb] reached +cycles=%0d", max_cycles);
    dump_wave_finish();
    $finish;
  end

  final begin
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
endmodule
