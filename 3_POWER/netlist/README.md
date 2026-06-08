# PTPX Netlist Inputs

This directory stores synthesized design files consumed by `../run_ptpx`.

## Expected Files

For the default top module:

- `BuckyballAccelerator.v`: mapped gate-level Verilog netlist.
- `BuckyballAccelerator.sdc`: synthesis constraints for PrimeTime.
- `BuckyballAccelerator.ddc`: Design Compiler database.
- `link_library.txt`: synthesis link-library record.

## Updating Inputs

The root flow copies the current synthesis outputs here:

```sh
cd /home/sjm/tapeout
./run_all
```

Manual update example:

```sh
cp /home/sjm/tapeout/1_SYN/outputs/$RUN_TAG/* /home/sjm/tapeout/3_POWER/netlist/
```

Then run PTPX:

```sh
cd /home/sjm/tapeout/3_POWER
./run_ptpx
```
