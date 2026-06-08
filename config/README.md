# Shared Configuration

`config/` contains shared environment and project configuration for all EDA
stages.

## Files

- `env.sh`: shell environment setup for Synopsys tools, RISC-V tools, license
  variables, stage directory names, `PATH`, and `LD_LIBRARY_PATH`.
- `project.tcl`: Tcl project configuration used by DC, PTPX, and Formality.
  It defines RTL filelists, top module, libraries, constraints, helper
  procedures, and selected synthesis output behavior.
- `rtl.f`: synthesis RTL filelist generated/maintained for the current flow.

## Usage

Stage wrapper scripts source this configuration automatically. Typical commands:

```sh
cd /home/sjm/tapeout
./run_all
```

```sh
cd /home/sjm/tapeout/1_SYN
./run_dc --top BuckyballAccelerator
```

Manual environment setup:

```sh
cd /home/sjm/tapeout
. config/env.sh
```

## Common Overrides

- `PROJECT_ROOT`: repository root.
- `CONFIG_DIR_NAME`, `RTL_STAGE_DIR_NAME`, `SYN_STAGE_DIR_NAME`,
  `POSTSIM_STAGE_DIR_NAME`, `POWER_STAGE_DIR_NAME`, `FM_STAGE_DIR_NAME`: stage
  directory names.
- `CONFIG_DIR`, `RTL_STAGE_DIR`, `SYN_STAGE_DIR`, `POSTSIM_STAGE_DIR`,
  `POWER_STAGE_DIR`, `FM_STAGE_DIR`: explicit stage paths.
- `TOP_MODULE`: top module for stages that read `project.tcl`.
- `CLOCK_PORT`, `CLOCK_NAME`: synthesis clock overrides.
- `SNPSLMD_LICENSE_FILE_OVERRIDE`, `LM_LICENSE_FILE_OVERRIDE`: license path
  overrides.
