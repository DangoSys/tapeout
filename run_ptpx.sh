#!/usr/bin/env bash
set -euo pipefail

export PRIMEHOME=/data2/tools/prime/R-2020.09-SP5-5
export PATH=$PRIMEHOME/bin:$PATH
export LD_LIBRARY_PATH=$PRIMEHOME/linux64/syn/bin:$PRIMEHOME/linux64/pt/shlib:$PRIMEHOME/linux64/pt/shlib2:/data0/tools/Synopsys/dc/syn/W-2024.09-SP1/linux64/syn/shlib:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

pt_shell -version
pt_shell -f "$SCRIPT_DIR/ptpx_power.tcl" | tee "$SCRIPT_DIR/ptpx.log"
