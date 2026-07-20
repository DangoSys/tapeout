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

run_tail() {
  local log="$1"
  shift
  "$@" > "$log" 2>&1
  local rc=$?
  tail -n 10 "$log"
  return $rc
}

echo "=== Chip: $CHIP (config: $VERILOG_CONFIG) ==="

# ---- 1. Copy RTL ----
echo "=== 1. Copy RTL ==="
VERILOG_DIR="$BUCKYBALL_DIR/arch/build/$VERILOG_CONFIG"
mkdir -p "$TAPEOUT_DIR/0_RTL/RTL"
cp "$VERILOG_DIR"/*.sv "$TAPEOUT_DIR/0_RTL/RTL/" 2>/dev/null
cp "$VERILOG_DIR"/*.v  "$TAPEOUT_DIR/0_RTL/RTL/" 2>/dev/null
(cd "$TAPEOUT_DIR/0_RTL/RTL" && ls *.sv *.v > filelist.f)
echo "RTL: $(wc -l < "$TAPEOUT_DIR/0_RTL/RTL/filelist.f") files"

# ---- 2. SRAM generation ----
echo "=== 2. SRAM generation ==="
cd "$TAPEOUT_DIR/0_RTL"
python3 scripts/gen_real_sram_libs.py

# ---- 3. DC synthesis ----
echo "=== 3. DC synthesis ==="
run_tail "$TAPEOUT_DIR/1_SYN/dc.log" bash -c "cd '$TAPEOUT_DIR/1_SYN' && . '$TAPEOUT_DIR/config/env.sh' && ./run_dc"

# ---- 4. Copy netlist ----
echo "=== 4. Copy netlist ==="
SYN_OUT=$(ls -td "$TAPEOUT_DIR/1_SYN/outputs/"*/ | head -1)
mkdir -p "$TAPEOUT_DIR/3_POWER/netlist"
cp "$SYN_OUT"/* "$TAPEOUT_DIR/3_POWER/netlist/"
ls -lh "$TAPEOUT_DIR/3_POWER/netlist/BuckyballAccelerator.v"

# ---- 5. VCS compile ----
echo "=== 5. VCS compile ==="
run_tail "$TAPEOUT_DIR/2_POSTSIM/glsim/compile.log" bash -c "cd '$TAPEOUT_DIR/2_POSTSIM/glsim' && . '$TAPEOUT_DIR/config/env.sh' && ./compile_mixed.sh"

# ---- 6. Prepare ELF ----
echo "=== 6. Prepare ELF ==="
ELF=$(find "$BUCKYBALL_DIR/bb-tests/output" -type f -name "*baremetal" 2>/dev/null | head -1)
[ -n "$ELF" ] && cp "$ELF" "$TAPEOUT_DIR/2_POSTSIM/glsim/elf/default.elf"

# ---- 7. VCS simulation ----
echo "=== 7. VCS simulation ==="
run_tail "$TAPEOUT_DIR/2_POSTSIM/glsim/sim.log" bash -c "cd '$TAPEOUT_DIR/2_POSTSIM/glsim' && ./run_mixed.sh"

# ---- 8. Copy SAIF ----
echo "=== 8. Copy SAIF ==="
SIM_OUT=$(basename $(ls -td "$TAPEOUT_DIR/2_POSTSIM/glsim/results/"*/ | head -1))
mkdir -p "$TAPEOUT_DIR/3_POWER/waveform"
cp "$TAPEOUT_DIR/2_POSTSIM/glsim/results/$SIM_OUT/glsim_mixed.saif" "$TAPEOUT_DIR/3_POWER/waveform/glsim_mixed.saif"
echo "SAIF: $(ls -lh "$TAPEOUT_DIR/3_POWER/waveform/glsim_mixed.saif" | awk '{print $5}')"

# # ---- 9. PTPX power analysis ----
# echo "=== 9. PTPX power analysis ==="
# cd "$TAPEOUT_DIR/3_POWER"
# MAX_RETRIES=10
# for i in $(seq 1 $MAX_RETRIES); do
#   echo "[PTPX] Attempt $i/$MAX_RETRIES..."
#   if ./run_ptpx; then
#     echo "[PTPX] Success on attempt $i"
#     break
#   fi
#   if [ "$i" -eq "$MAX_RETRIES" ]; then
#     echo "[PTPX] Failed after $MAX_RETRIES attempts"
#     exit 1
#   fi
#   echo "[PTPX] Retrying..."
#   sleep 2
# done

echo ""
echo "DONE"
