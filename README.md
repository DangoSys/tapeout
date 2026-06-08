# Buckyball Tapeout Flow

This repository contains a staged tapeout flow for the Buckyball design. The
main entry point is `./run_all`, which connects synthesis, mixed gate-level
simulation, SAIF generation, and PrimeTime PX power analysis.

## Directory Map

- `0_RTL/`: generated RTL, memory replacement outputs, and real SRAM library
  collateral used by synthesis, simulation, Formality, and PTPX.
- `1_SYN/`: Design Compiler synthesis flow. It produces mapped Verilog, DDC,
  SDC, logs, and timing/area/power reports.
- `2_POSTSIM/`: post-synthesis simulation area. The `glsim/` subdirectory
  builds and runs the mixed RTL/gate-level VCS simulation.
- `3_POWER/`: PrimeTime PX power analysis flow. It consumes the synthesized
  netlist, SDC, and SAIF activity.
- `4_FM/`: Formality equivalence checking between RTL and the synthesized
  implementation.
- `config/`: shared environment and project configuration used by all EDA
  stages.

Generated run artifacts live under stage-local directories such as `logs/`,
`outputs/`, `rpt/`, `build/`, `results/`, `alib-52/`, and `elab/`.

## Main Flow

First copy the `.v`/`.sv` design files and `filelist.f` to `0_RTL/RTL`.

Run the default end-to-end accelerator flow from the repository root:

```sh
./run_all
```

This runs:

1. `1_SYN/run_dc`
2. Copies the current synthesis outputs to `3_POWER/netlist/`
3. `2_POSTSIM/glsim/compile_mixed.sh`
4. `2_POSTSIM/glsim/run_mixed.sh`
5. Copies the generated SAIF to `3_POWER/waveform/`
6. `3_POWER/run_ptpx`

Default mixed-simulation settings:

```sh
ELF=2_POSTSIM/glsim/elf/default.elf
CYCLES=5000000
PROGRESS=200000
DUMP_VCD=1
BB_SAIF=1
```

If a custom top module is selected, only synthesis is run:

```sh
./run_all --top ChipTop
```

## `run_all`

Usage:

```sh
./run_all [--top TOP_MODULE] [--elf ELF] [--cycles N] [--progress N] [--dump-vcd 0|1] [--bb-saif 0|1] [--help]
```

Options:

- `--top TOP_MODULE`: synthesis top module. The default is
  `BuckyballAccelerator`. Any non-default top stops after synthesis.
- `--elf ELF`: bare-metal ELF loaded by the mixed simulation.
- `--cycles N`: simulation cycle limit.
- `--progress N`: simulation progress print interval.
- `--dump-vcd 0|1`: enable or disable VCD dumping.
- `--bb-saif 0|1`: enable or disable the Buckyball SAIF activity window.
- `--help`: print the script help.

Environment overrides:

- `RUN_TAG`: run directory tag shared across stages.
- `TOP_MODULE`: same purpose as `--top`.
- `ELF`, `CYCLES`, `PROGRESS`, `DUMP_VCD`, `BB_SAIF`: mixed-simulation
  controls.
- `RUN_NAME`, `OUT_DIR`: mixed-simulation result naming/location.
- `DUMP_FST`, `DUMP_SAIF`, `TIMINGCHECKS`, `VCD_FILTER`, `ZERO_INIT`,
  `EXTRA_ARGS`: forwarded to `run_mixed.sh`.

## Running Stages Manually

Synthesis only:

```sh
cd 1_SYN
./run_dc --top BuckyballAccelerator
```

Mixed simulation only, after a netlist is available in `3_POWER/netlist/`:

```sh
cd 2_POSTSIM/glsim
./compile_mixed.sh
ELF=/home/sjm/tapeout/2_POSTSIM/glsim/elf/default.elf \
CYCLES=5000000 \
PROGRESS=200000 \
DUMP_VCD=1 \
BB_SAIF=1 \
./run_mixed.sh
```

PTPX only, after netlist, SDC, and SAIF are available:

```sh
cd 3_POWER
./run_ptpx
```

Formality only:

```sh
cd 4_FM
./run_fm
```
