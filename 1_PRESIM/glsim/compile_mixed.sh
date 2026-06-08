#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
GLSIM_DIR="$ROOT/1_PRESIM/glsim"
BUCKYBALL_BUILD=${BUCKYBALL_BUILD:-/home/sjm/buckyball/arch/build/sims.verilator.BuckyballToyVerilatorConfig}
NETLIST=${NETLIST:-$ROOT/3_POWER/netlist/BuckyballAccelerator.v}
BUILD_DIR=${BUILD_DIR:-$GLSIM_DIR/build}
PATCHED_NETLIST=${PATCHED_NETLIST:-$BUILD_DIR/BuckyballAccelerator.queue_ram_zero.v}
SIMV=${SIMV:-$BUILD_DIR/simv_mixed}
RANDOMIZE_RTL=${RANDOMIZE_RTL:-1}
ZERO_RANDOM=${ZERO_RANDOM:-1}
USE_OFFICIAL_BWP40=${USE_OFFICIAL_BWP40:-1}
INITREG_SUPPORT=${INITREG_SUPPORT:-1}
OFFICIAL_BWP40_TAR=${OFFICIAL_BWP40_TAR:-/data0/tsmc28/TSMC28/logic/tcbn28hpcplusbwp40p140_180b/AN61001_20180509/tcbn28hpcplusbwp40p140_110a_vlg.tar.gz}
OFFICIAL_BWP40_MEMBER=${OFFICIAL_BWP40_MEMBER:-TSMCHOME/digital/Front_End/verilog/tcbn28hpcplusbwp40p140_110a/tcbn28hpcplusbwp40p140.v}
OFFICIAL_BWP40_MODEL=${OFFICIAL_BWP40_MODEL:-$BUILD_DIR/official/tcbn28hpcplusbwp40p140.v}

mkdir -p "$BUILD_DIR"

if [ "$USE_OFFICIAL_BWP40" != "0" ]; then
  mkdir -p "$(dirname "$OFFICIAL_BWP40_MODEL")"
  tar -xOf "$OFFICIAL_BWP40_TAR" "$OFFICIAL_BWP40_MEMBER" > "$OFFICIAL_BWP40_MODEL"
  CELL_MODEL="$OFFICIAL_BWP40_MODEL"
else
  python3 "$GLSIM_DIR/scripts/make_bwp40_model.py" \
    --netlist "$NETLIST" \
    --out "$BUILD_DIR/bwp40p140_cells.v"
  CELL_MODEL="$BUILD_DIR/bwp40p140_cells.v"
fi

python3 "$GLSIM_DIR/scripts/patch_accel_queue_rams.py" \
  --in-netlist "$NETLIST" \
  --out-netlist "$PATCHED_NETLIST"

python3 "$GLSIM_DIR/scripts/make_mixed_filelist.py" \
  --buckyball-build "$BUCKYBALL_BUILD" \
  --netlist "$PATCHED_NETLIST" \
  --cell-model "$CELL_MODEL" \
  --sram-root "$ROOT/0_RTL/real_sram_libs/compiler_runs" \
  --tb "$GLSIM_DIR/tb_glsim_mixed.sv" \
  --out "$BUILD_DIR/rtl_mixed.f"

cd "$GLSIM_DIR"

RANDOMIZE_DEFINES=""
if [ "$RANDOMIZE_RTL" != "0" ]; then
  RANDOMIZE_DEFINES="+define+RANDOMIZE_MEM_INIT +define+RANDOMIZE_REG_INIT +define+RANDOMIZE_GARBAGE_ASSIGN +define+RANDOMIZE_INVALID_ASSIGN"
  if [ "$ZERO_RANDOM" != "0" ]; then
    RANDOMIZE_DEFINES="$RANDOMIZE_DEFINES +define+RANDOM=0"
  fi
fi
INITREG_ARGS=""
if [ "$INITREG_SUPPORT" != "0" ]; then
  INITREG_ARGS="+vcs+initreg+random"
fi

# shellcheck disable=SC2086
vcs \
  -full64 \
  -sverilog \
  -timescale=1ns/1ps \
  +v2k \
  $RANDOMIZE_DEFINES \
  $INITREG_ARGS \
  +define+RANDOMIZE_DELAY=0 \
  +define+TETRAMAX \
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
