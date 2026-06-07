#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
GLSIM_DIR="$ROOT/1_PRESIM/glsim"
BUCKYBALL_BUILD=${BUCKYBALL_BUILD:-/home/sjm/buckyball/arch/build/sims.verilator.BuckyballToyVerilatorConfig}
NETLIST=${NETLIST:-$ROOT/3_POWER/netlist/BuckyballAccelerator.v}
BUILD_DIR=${BUILD_DIR:-$GLSIM_DIR/build}
SIMV=${SIMV:-$BUILD_DIR/simv_mixed}
RANDOMIZE_RTL=${RANDOMIZE_RTL:-1}

mkdir -p "$BUILD_DIR"

python3 "$GLSIM_DIR/scripts/make_bwp40_model.py" \
  --netlist "$NETLIST" \
  --out "$BUILD_DIR/bwp40p140_cells.v"

python3 "$GLSIM_DIR/scripts/make_mixed_filelist.py" \
  --buckyball-build "$BUCKYBALL_BUILD" \
  --netlist "$NETLIST" \
  --cell-model "$BUILD_DIR/bwp40p140_cells.v" \
  --sram-root "$ROOT/0_RTL/real_sram_libs/compiler_runs" \
  --tb "$GLSIM_DIR/tb_glsim_mixed.sv" \
  --out "$BUILD_DIR/rtl_mixed.f"

cd "$GLSIM_DIR"

RANDOMIZE_DEFINES=""
if [ "$RANDOMIZE_RTL" != "0" ]; then
  RANDOMIZE_DEFINES="+define+RANDOMIZE_MEM_INIT +define+RANDOMIZE_REG_INIT +define+RANDOMIZE_GARBAGE_ASSIGN +define+RANDOMIZE_INVALID_ASSIGN"
fi

# shellcheck disable=SC2086
vcs \
  -full64 \
  -sverilog \
  -timescale=1ns/1ps \
  +v2k \
  $RANDOMIZE_DEFINES \
  +define+RANDOMIZE_DELAY=0 \
  +define+no_warning \
  +define+PRINTF_COND=0 \
  +define+ASSERT_VERBOSE_COND=0 \
  +define+STOP_COND=0 \
  -debug_access+all \
  -kdb \
  -lca \
  -top tb_glsim_mixed \
  -f "$BUILD_DIR/rtl_mixed.f" \
  "$GLSIM_DIR/csrc/vcs_bbsim_dpi.cpp" \
  -CFLAGS "-std=c++17" \
  -o "$SIMV" \
  -l "$BUILD_DIR/compile_mixed.log"

echo "[compile] built $SIMV"
