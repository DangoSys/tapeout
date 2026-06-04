#!/usr/bin/env bash
set -euo pipefail

export DCHOME=${DCHOME:-/data0/tools/Synopsys/dc/syn/W-2024.09-SP1}
export PATH=$DCHOME/bin:$PATH
export LD_LIBRARY_PATH=$DCHOME/linux64/syn/shlib:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

dc_shell -version || true
dc_shell -f "$SCRIPT_DIR/dc_synth.tcl" | tee "$SCRIPT_DIR/dc.log"
