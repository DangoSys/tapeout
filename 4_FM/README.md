# Formality Stage

`4_FM/` runs Synopsys Formality to compare the RTL reference design against the
synthesized implementation.

## Subdirectories

- `scripts/`: Formality Tcl script.
- `rpt/`: generated equivalence reports.
- `logs/`: generated Formality logs.

## `run_fm`

Usage:

```sh
cd /home/sjm/tapeout/4_FM
./run_fm
```

Environment overrides:

- `RUN_TAG`: report/log directory tag.
- `TOP_MODULE`: top module to verify. Default comes from `config/project.tcl`
  unless overridden.
- `CONFIG_DIR`, `PROJECT_ROOT`, `FM_STAGE_DIR`: stage/config location overrides.

Example:

```sh
RUN_TAG=fm_buckyball TOP_MODULE=BuckyballAccelerator ./run_fm
```

The script reads the selected synthesis output directory from
`config/project.tcl`. If `PT_DC_RUN_TAG` is empty there, the latest directory
under `1_SYN/outputs/` is used.
