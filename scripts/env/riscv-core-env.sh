#!/usr/bin/env sh
# Source this file to enable the RISC-V core RTL development toolchain.

export RISCV_CORE_TOOLS="${RISCV_CORE_TOOLS:-$HOME/.local/riscv-core-tools}"
export RISCV_CORE_OSS_CAD_SUITE="$RISCV_CORE_TOOLS/opt/oss-cad-suite/current"
export RISCV_CORE_VERIBLE="$RISCV_CORE_TOOLS/opt/verible/current"
export RISCV_CORE_RISCV_GNU_TOOLCHAIN="$RISCV_CORE_TOOLS/opt/riscv-gnu-toolchain/current"
export RISCV="$RISCV_CORE_RISCV_GNU_TOOLCHAIN"
export RISCV_CORE_COCOTB_VENV="$RISCV_CORE_TOOLS/python/cocotb-venv"

riscv_core_prepend_path() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1:$PATH" ;;
  esac
}

riscv_core_prepend_path "$RISCV_CORE_TOOLS/bin"
riscv_core_prepend_path "$RISCV_CORE_OSS_CAD_SUITE/bin"
riscv_core_prepend_path "$RISCV_CORE_VERIBLE/bin"
riscv_core_prepend_path "$RISCV_CORE_RISCV_GNU_TOOLCHAIN/bin"

if [ -d "$RISCV_CORE_COCOTB_VENV/bin" ]; then
  riscv_core_prepend_path "$RISCV_CORE_COCOTB_VENV/bin"
  export VIRTUAL_ENV="$RISCV_CORE_COCOTB_VENV"
fi

export PATH
unset -f riscv_core_prepend_path
