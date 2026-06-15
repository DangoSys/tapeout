#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
POSTSIM_STAGE_DIR=${POSTSIM_STAGE_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
GLSIM_DIR=${GLSIM_DIR:-$SCRIPT_DIR}
BUILD_DIR=${BUILD_DIR:-$GLSIM_DIR/build}
SIMV=${SIMV:-$BUILD_DIR/simv_mixed}
ELF=${ELF:-$GLSIM_DIR/elf/default.elf}
CYCLES=${CYCLES:-5000000}
PROGRESS=${PROGRESS:-100000}
START=${START:-}
STOP=${STOP:-}
RUN_NAME=${RUN_NAME:-$(date +%m%d_%H%M%S_mixed)}
OUT_DIR=${OUT_DIR:-$GLSIM_DIR/results/$RUN_NAME}
TIMINGCHECKS=${TIMINGCHECKS:-0}
VCD_FILTER=${VCD_FILTER:-1}
DUMP_VCD=${DUMP_VCD:-1}
DUMP_FST=${DUMP_FST:-1}
DUMP_SAIF=${DUMP_SAIF:-1}
BB_SAIF=${BB_SAIF:-0}
EXTRA_ARGS=${EXTRA_ARGS:-}
ZERO_INIT=${ZERO_INIT:-1}

mkdir -p "$OUT_DIR"

if [ ! -x "$SIMV" ]; then
  echo "[run] missing simulator: $SIMV" >&2
  echo "[run] run ./compile_mixed.sh first" >&2
  exit 1
fi

if [ ! -f "$ELF" ]; then
  echo "[run] missing ELF: $ELF" >&2
  exit 1
fi

case "$START" in
  ""|*[!0-9]*)
    if [ -n "$START" ]; then
      echo "[run] invalid START: $START" >&2
      exit 1
    fi
    ;;
esac

case "$STOP" in
  ""|*[!0-9]*)
    if [ -n "$STOP" ]; then
      echo "[run] invalid STOP: $STOP" >&2
      exit 1
    fi
    ;;
esac

BB_CYCLE_WINDOW=0
if [ -n "$START" ] || [ -n "$STOP" ]; then
  BB_CYCLE_WINDOW=1
fi

cd "$OUT_DIR"
echo "[run] simv=$SIMV"
echo "[run] elf=$ELF"
echo "[run] cycles=$CYCLES progress=$PROGRESS"
if [ "$BB_CYCLE_WINDOW" != "0" ]; then
  echo "[run] buckyball window start=${START:-0} stop=${STOP:-max_cycles}"
fi
echo "[run] out=$OUT_DIR"
if [ "$TIMINGCHECKS" = "0" ]; then
  echo "[run] timing checks disabled (+notimingcheck)"
else
  echo "[run] timing checks enabled"
fi
if [ "$DUMP_VCD" = "0" ]; then
  VCD_FILTER=0
  VCD_FILE="$OUT_DIR/glsim_mixed.vcd"
  echo "[run] VCD disabled"
elif [ "$VCD_FILTER" = "0" ]; then
  VCD_FILE="$OUT_DIR/glsim_mixed.vcd"
  echo "[run] VCD filter disabled"
else
  VCD_FILE="$OUT_DIR/glsim_mixed.raw.vcd"
  echo "[run] VCD filter enabled: removing accelerator internals"
fi
FINAL_VCD_FILE="$OUT_DIR/glsim_mixed.vcd"
FST_FILE="${FINAL_VCD_FILE%.vcd}.fst"
if [ "$DUMP_VCD" = "0" ]; then
  DUMP_FST=0
fi
if [ "$DUMP_FST" = "0" ]; then
  echo "[run] FST disabled"
else
  echo "[run] FST enabled: converting VCD to FST"
fi
if [ "$DUMP_SAIF" = "0" ]; then
  echo "[run] SAIF disabled"
elif [ "$BB_CYCLE_WINDOW" != "0" ]; then
  echo "[run] SAIF mode: BB_SAIF cycle window"
elif [ "$BB_SAIF" = "0" ]; then
  echo "[run] SAIF mode: full simulation"
else
  echo "[run] SAIF mode: BB_SAIF window"
fi

if [ "$DUMP_FST" != "0" ] && ! command -v vcd2fst >/dev/null 2>&1; then
  echo "[run] missing vcd2fst; set DUMP_FST=0 to skip FST generation" >&2
  exit 1
fi

set -- "$SIMV" \
  +batch \
  +elf="$ELF" \
  +cycles="$CYCLES" \
  +progress="$PROGRESS" \
  +vcd="$VCD_FILE" \
  +saif="$OUT_DIR/glsim_mixed.saif" \
  +stdout="$OUT_DIR/stdout.log" \
  -no_save \
  -suppress=ASLR_DETECTED_INFO \
  -l "$OUT_DIR/sim.log"

if [ "$TIMINGCHECKS" = "0" ]; then
  set -- "$@" +notimingcheck
fi

if [ "$ZERO_INIT" != "0" ]; then
  set -- "$@" +vcs+initreg+0
fi

if [ "$DUMP_VCD" = "0" ]; then
  set -- "$@" +no_vcd
fi

if [ "$DUMP_SAIF" = "0" ]; then
  set -- "$@" +no_saif
fi

if [ "$DUMP_SAIF" != "0" ] && { [ "$BB_SAIF" != "0" ] || [ "$BB_CYCLE_WINDOW" != "0" ]; }; then
  set -- "$@" +BB_SAIF
fi

if [ -n "$START" ]; then
  set -- "$@" +bb_window_start_cycle="$START"
fi

if [ -n "$STOP" ]; then
  set -- "$@" +bb_window_stop_cycle="$STOP"
fi

if [ -n "$EXTRA_ARGS" ]; then
  # shellcheck disable=SC2086
  set -- "$@" $EXTRA_ARGS
fi

"$@"

if [ "$DUMP_VCD" != "0" ] && [ "$VCD_FILTER" != "0" ]; then
  python3 "$GLSIM_DIR/scripts/filter_vcd_scope.py" \
    --in "$OUT_DIR/glsim_mixed.raw.vcd" \
    --out "$OUT_DIR/glsim_mixed.vcd" \
    --scope "tb_glsim_mixed.dut.chiptop0.system.tile_prci_domain.element_reset_domain_bbtile.accelerators_0"
  rm -f "$OUT_DIR/glsim_mixed.raw.vcd"
fi

if [ "$DUMP_FST" != "0" ]; then
  vcd2fst "$FINAL_VCD_FILE" "$FST_FILE"
fi

if [ "$DUMP_VCD" != "0" ]; then
  echo "[run] VCD : $FINAL_VCD_FILE"
fi
if [ "$DUMP_FST" != "0" ]; then
  echo "[run] FST : $FST_FILE"
fi
if [ "$DUMP_SAIF" != "0" ]; then
  echo "[run] SAIF: $OUT_DIR/glsim_mixed.saif"
fi
