#!/bin/sh
# Synopsys/RISC-V environment for the Buckyball tapeout flow.

export PRIMEHOME="${PRIMEHOME:-/data2/tools/prime/R-2020.09-SP5-5}"
export DC_HOME="${DC_HOME:-/data0/tools/Synopsys/dc/syn/W-2024.09-SP1}"
export PT_HOME="${PT_HOME:-/data0/tools/Synopsys/ptpx/prime/W-2024.09-SP1}"
export FM_HOME="${FM_HOME:-/data2/tools/fm/R-2020.09-SP5}"
export VCS_HOME="${VCS_HOME:-/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1}"
export VERDI_HOME="${VERDI_HOME:-/data0/tools/Synopsys/verdi/verdi/W-2024.09-SP1}"
export SCL_HOME="${SCL_HOME:-/data0/tools/Synopsys/scl/scl/2024.06}"

export CONFIG_DIR_NAME="${CONFIG_DIR_NAME:-config}"
export RTL_STAGE_DIR_NAME="${RTL_STAGE_DIR_NAME:-0_RTL}"
export POSTSIM_STAGE_DIR_NAME="${POSTSIM_STAGE_DIR_NAME:-2_POSTSIM}"
export SYN_STAGE_DIR_NAME="${SYN_STAGE_DIR_NAME:-1_SYN}"
export POWER_STAGE_DIR_NAME="${POWER_STAGE_DIR_NAME:-3_POWER}"
export FM_STAGE_DIR_NAME="${FM_STAGE_DIR_NAME:-4_FM}"

if [ -n "${PROJECT_ROOT:-}" ]; then
  export CONFIG_DIR="${CONFIG_DIR:-$PROJECT_ROOT/$CONFIG_DIR_NAME}"
  export RTL_STAGE_DIR="${RTL_STAGE_DIR:-$PROJECT_ROOT/$RTL_STAGE_DIR_NAME}"
  export POSTSIM_STAGE_DIR="${POSTSIM_STAGE_DIR:-$PROJECT_ROOT/$POSTSIM_STAGE_DIR_NAME}"
  export SYN_STAGE_DIR="${SYN_STAGE_DIR:-$PROJECT_ROOT/$SYN_STAGE_DIR_NAME}"
  export POWER_STAGE_DIR="${POWER_STAGE_DIR:-$PROJECT_ROOT/$POWER_STAGE_DIR_NAME}"
  export FM_STAGE_DIR="${FM_STAGE_DIR:-$PROJECT_ROOT/$FM_STAGE_DIR_NAME}"
fi

export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE_OVERRIDE:-26000@amax}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE_OVERRIDE:-/data0/tools/Synopsys/lic/Synopsys.dat}"

prepend_path() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1:$PATH" ;;
  esac
}

prepend_ld_path() {
  case ":${LD_LIBRARY_PATH:-}:" in
    *":$1:"*) ;;
    *) LD_LIBRARY_PATH="$1:${LD_LIBRARY_PATH:-}" ;;
  esac
}

prepend_path "$PRIMEHOME/bin"
prepend_path "$DC_HOME/bin"
prepend_path "$PT_HOME/bin"
prepend_path "$FM_HOME/bin"
prepend_path "$VCS_HOME/bin"
prepend_path "$VERDI_HOME/bin"
prepend_path "$SCL_HOME/linux64/bin"
prepend_path "/opt/riscv/bin"

prepend_ld_path "$PRIMEHOME/linux64/syn/bin"
prepend_ld_path "$PRIMEHOME/linux64/pt/shlib"
prepend_ld_path "$PRIMEHOME/linux64/pt/shlib2"
prepend_ld_path "$DC_HOME/linux64/syn/shlib"
prepend_ld_path "/lib/x86_64-linux-gnu"
prepend_ld_path "/usr/lib/x86_64-linux-gnu"

export PATH
export LD_LIBRARY_PATH
