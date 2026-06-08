# RTL Stage

`0_RTL/` contains the RTL source tree and generated memory collateral used by
the downstream synthesis, simulation, power, and Formality stages.

## Subdirectories

- `RTL/`: SystemVerilog and Verilog design sources, plus the source filelist.
- `generated/`: generated synthesis helper RTL, including SRAM replacement
  wrappers and synthesis stubs.
- `real_sram_libs/`: real TSMC28 SRAM compiler outputs, generated manifests,
  and library fragments consumed by `config/project.tcl`.
- `scripts/`: helper scripts for SRAM discovery and compiler collateral
  generation.

## Main Script

Generate or refresh real SRAM compiler collateral:

```sh
cd 0_RTL
python3 scripts/gen_real_sram_libs.py
```

The repository-level `./run_all` script runs this step before synthesis.

Useful options:

- `--rtl-dir DIR`: RTL directory to scan. Default: `0_RTL/RTL`.
- `--out-dir DIR`: output directory for SRAM compiler collateral. Default:
  `0_RTL/real_sram_libs`.
- `--skip-db`: skip Library Compiler `.db` conversion.
- `--force`: regenerate compiler runs even when existing kits are present.
- `--discover-only`: only write manifests; do not run memory compilers.


