# Synthesis Stage

`1_SYN/` runs the Synopsys Design Compiler flow. It reads RTL and shared project
configuration, generates SRAM replacement RTL, synthesizes the selected top
module, and writes mapped outputs and reports.

## Subdirectories

- `scripts/`: DC Tcl scripts, constraints, and SRAM replacement helpers.
- `outputs/`: per-run synthesis outputs such as `.v`, `.ddc`, `.sdc`, and
  `link_library.txt`.
- `rpt/`: per-run timing, area, constraint, and power reports.
- `logs/`: per-run DC logs.
- `elab/`, `alib-52/`: Design Compiler working directories.

## `run_dc`

Usage:

```sh
cd /home/sjm/tapeout/1_SYN
./run_dc [--top TOP_MODULE] [--help]
```

Options:

- `--top TOP_MODULE`: synthesis top module. Default:
  `BuckyballAccelerator`.
- `--help`: print help.

Environment overrides:

- `RUN_TAG`: output/report/log directory tag.
- `TOP_MODULE`: same purpose as `--top`.
- `CLOCK_PORT`, `CLOCK_NAME`: override clock constraint names.

Examples:

```sh
./run_dc
./run_dc --top BuckyballAccelerator
RUN_TAG=my_syn_run ./run_dc --top ChipTop
```

## Outputs

For a run tag `$RUN_TAG` and top `$TOP_MODULE`, DC writes:

- `outputs/$RUN_TAG/$TOP_MODULE.v`
- `outputs/$RUN_TAG/$TOP_MODULE.ddc`
- `outputs/$RUN_TAG/$TOP_MODULE.sdc`
- `outputs/$RUN_TAG/link_library.txt`
- `rpt/$RUN_TAG/*`
- `logs/dc_$RUN_TAG.log`

The synthesis script does not copy these files into `3_POWER/netlist/`.
`./run_all` performs that copy for the default full flow.
