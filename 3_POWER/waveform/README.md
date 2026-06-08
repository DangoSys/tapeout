# PTPX Activity Inputs

This directory stores activity files consumed by PrimeTime PX.

## Expected File

- `glsim_mixed.saif`: default SAIF file read by `../run_ptpx`.

The root `./run_all` flow copies the SAIF produced by
`2_POSTSIM/glsim/run_mixed.sh` into this directory before launching PTPX.

## Manual Usage

Copy a SAIF file into this directory:

```sh
cp /path/to/glsim_mixed.saif /home/sjm/tapeout/3_POWER/waveform/glsim_mixed.saif
```
