#!/bin/bash

CHIP="${1:-pebble}"

case "$CHIP" in
  pebble)
    VERILOG_CONFIG="sims.verilator.BuckyballPebbleVerilatorConfig"
    ;;
  toy)
    VERILOG_CONFIG="sims.verilator.BuckyballToyVerilatorConfig"
    ;;
  *)
    echo "Usage: $0 [toy|pebble]" >&2
    exit 1
    ;;
esac

: "${BUCKYBALL_DIR:=$HOME/Code/buckyball}"
TAPEOUT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

echo "=== Chip: $CHIP (config: $VERILOG_CONFIG) ==="

# ---- Copy RTL ----
echo "=== Copy RTL ==="
VERILOG_DIR="$BUCKYBALL_DIR/arch/build/$VERILOG_CONFIG"
mkdir -p "$TAPEOUT_DIR/0_RTL/RTL"
cp "$VERILOG_DIR"/*.sv "$TAPEOUT_DIR/0_RTL/RTL/" 2>/dev/null
cp "$VERILOG_DIR"/*.v  "$TAPEOUT_DIR/0_RTL/RTL/" 2>/dev/null
(cd "$TAPEOUT_DIR/0_RTL/RTL" && ls *.sv *.v > filelist.f)
echo "RTL: $(wc -l < "$TAPEOUT_DIR/0_RTL/RTL/filelist.f") files"

# ---- Stage 0: SRAM ----
echo "=== Stage 0: SRAM generation ==="
cd "$TAPEOUT_DIR/0_RTL"
python3 scripts/gen_real_sram_libs.py

# ---- Stage 1-2: DC synthesis ----
echo "=== Stage 1-2: DC synthesis ==="
( cd "$TAPEOUT_DIR/1_SYN" && . "$TAPEOUT_DIR/config/env.sh" && ./run_dc )

# ---- Stage 3: Copy netlist ----
echo "=== Stage 3: Copy netlist ==="
SYN_OUT=$(ls -td "$TAPEOUT_DIR/1_SYN/outputs/"*/ | head -1)
mkdir -p "$TAPEOUT_DIR/3_POWER/netlist"
cp "$SYN_OUT"/* "$TAPEOUT_DIR/3_POWER/netlist/"
ls -lh "$TAPEOUT_DIR/3_POWER/netlist/BuckyballAccelerator.v"

# ---- Stage 4: VCS compile ----
echo "=== Stage 4: VCS compile ==="
( cd "$TAPEOUT_DIR/2_POSTSIM/glsim" && . "$TAPEOUT_DIR/config/env.sh" && ./compile_mixed.sh )

# ---- Stage 5: Prepare ELF ----
echo "=== Stage 5: Prepare ELF ==="
ELF=$(find "$BUCKYBALL_DIR/bb-tests/output" -type f -name "*baremetal" 2>/dev/null | head -1)
[ -n "$ELF" ] && cp "$ELF" "$TAPEOUT_DIR/2_POSTSIM/glsim/elf/default.elf"

# ---- Stage 6: VCS simulation ----
echo "=== Stage 6: VCS simulation ==="
( cd "$TAPEOUT_DIR/2_POSTSIM/glsim" && ./run_mixed.sh )

# ---- Stage 7: Copy SAIF ----
echo "=== Stage 7: Copy SAIF ==="
SIM_OUT=$(basename $(ls -td "$TAPEOUT_DIR/2_POSTSIM/glsim/results/"*/ | head -1))
mkdir -p "$TAPEOUT_DIR/3_POWER/waveform"
cp "$TAPEOUT_DIR/2_POSTSIM/glsim/results/$SIM_OUT/glsim_mixed.saif" "$TAPEOUT_DIR/3_POWER/waveform/glsim_mixed.saif"
echo "SAIF: $(ls -lh "$TAPEOUT_DIR/3_POWER/waveform/glsim_mixed.saif" | awk '{print $5}')"

# ---- Stage 8: PTPX ----
echo "=== Stage 8: PTPX power analysis ==="
cd "$TAPEOUT_DIR/3_POWER"
MAX_RETRIES=10
for i in $(seq 1 $MAX_RETRIES); do
  echo "[PTPX] Attempt $i/$MAX_RETRIES..."
  if ./run_ptpx; then
    echo "[PTPX] Success on attempt $i"
    break
  fi
  if [ "$i" -eq "$MAX_RETRIES" ]; then
    echo "[PTPX] Failed after $MAX_RETRIES attempts"
    exit 1
  fi
  echo "[PTPX] Retrying..."
  sleep 2
done

echo ""
echo "DONE"
