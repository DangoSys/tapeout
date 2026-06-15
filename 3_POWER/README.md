# Power Analysis Stage

`3_POWER/` measures power for both the synthesized accelerator logic (via
PrimeTime PX) and the external DRAM (via DRAMSim2).

## Accelerator Power (`run_ptpx`)

Uses PrimeTime PX with the synthesized netlist, SDC, and SAIF/VCD activity
from mixed simulation.

```sh
cd /home/sjm/test/tapeout/3_POWER
./run_ptpx
```

Environment overrides:

- `RUN_TAG`: output/report/log directory tag.
- `PTPX_TOP_MODULE`: top module for PTPX. Default: `BuckyballAccelerator`.
- `PTPX_NETLIST_FILE`: input netlist. Default:
  `netlist/${PTPX_TOP_MODULE}.v`.
- `PTPX_SDC_FILE`: input SDC. Default: `netlist/${PTPX_TOP_MODULE}.sdc`.
- `PTPX_ACTIVITY_FILE`: input activity. Default:
  `waveform/glsim_mixed.saif`.
- `PTPX_ACTIVITY_FORMAT`: activity format. Default: `saif`.
- `PTPX_STRIP_PATH`: activity hierarchy strip path.

## DRAM Power (`run_dram_power`)

External DRAM is outside the synthesized netlist, so it is measured separately
from the memory traffic seen by `BBSimDRAM` in mixed simulation.

`2_POSTSIM/glsim/run_mixed.sh` emits a DRAM AXI burst trace:

```
2_POSTSIM/glsim/results/$RUN_NAME/dram_trace.csv
```

`run_dram_power` converts the CSV to a DRAMSim2 misc-format trace and runs
the simulator:

```sh
cd /home/sjm/test/tapeout/3_POWER
./run_dram_power
```

The script:

1. Locates the latest `dram_trace.csv` under `2_POSTSIM/glsim/results/`.
2. Converts it to misc-format trace (`outputs/$RUN_TAG/misc_dramsim2.trc`).
3. Runs DRAMSim2 from the submodule at `tools/DRAMSim2`.
4. Prints the epoch power breakdown from DRAMSim2's output.

Environment overrides:

- `DRAM_TRACE_FILE`: explicit path to a `dram_trace.csv`.
- `DRAMSIM_CYCLES`: simulation cycles (default `120000`, must exceed
  `EPOCH_LENGTH` in system.ini).
- `DRAMSIM_SIZE`: memory size in MB (default `4096`).

### DRAMSim2 Submodule

The simulator lives at the repo root under `tools/DRAMSim2`
(`https://github.com/firesim/DRAMSim2.git`). The first run builds it
automatically if the binary is missing.

### Configuration

- `dramsim2_cfg/system.ini`: memory-system parameters (channels, queues,
  scheduling policy, epoch length, etc.).
- Device model: `tools/DRAMSim2/ini/DDR3_micron_64M_8B_x4_sg15.ini`.

### Trace Samples

The `dramtrace/` folder holds small `dram_trace.csv` files for quick
testing without a full mixed simulation:

```sh
DRAM_TRACE_FILE=dramtrace/dram_trace.csv ./run_dram_power
```

## Output Layout

```
outputs/$RUN_TAG/
├── misc_dramsim2.trc       # DRAMSim2 misc-format trace
└── dramsim2_stdout.log     # DRAMSim2 console output (contains Power Data)
```

Power Data lines are extracted to stdout by `run_dram_power`.