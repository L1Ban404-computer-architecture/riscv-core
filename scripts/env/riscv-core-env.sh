#!/usr/bin/env sh
# Source this file to enable the RISC-V core RTL development toolchain.

export RISCV_CORE_TOOLS="${RISCV_CORE_TOOLS:-$HOME/.local/riscv-core-tools}"
export RISCV_CORE_OSS_CAD_SUITE="$RISCV_CORE_TOOLS/opt/oss-cad-suite/current"
export RISCV_CORE_SLANG_SERVER="$RISCV_CORE_TOOLS/opt/slang-server/current"
export RISCV_CORE_RISCV_GNU_TOOLCHAIN="$RISCV_CORE_TOOLS/opt/riscv-gnu-toolchain/current"
export RISCV_CORE_SURFER="$RISCV_CORE_TOOLS/opt/surfer/current"
export RISCV="$RISCV_CORE_RISCV_GNU_TOOLCHAIN"
export RISCV_CORE_COCOTB_VENV="$RISCV_CORE_TOOLS/python/cocotb-venv"

riscv_core_prepend_path() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1:$PATH" ;;
  esac
}

riscv_core_remove_path() {
  new_path=
  old_ifs=$IFS
  IFS=:
  for path_entry in $PATH; do
    if [ "$path_entry" = "$1" ]; then
      continue
    fi
    if [ -z "$new_path" ]; then
      new_path=$path_entry
    else
      new_path=$new_path:$path_entry
    fi
  done
  IFS=$old_ifs
  PATH=$new_path
}

riscv_core_remove_path "$RISCV_CORE_TOOLS/opt/slang/current/bin"
riscv_core_prepend_path "$RISCV_CORE_TOOLS/bin"
riscv_core_prepend_path "$RISCV_CORE_OSS_CAD_SUITE/bin"
riscv_core_prepend_path "$RISCV_CORE_SLANG_SERVER"
riscv_core_prepend_path "$RISCV_CORE_RISCV_GNU_TOOLCHAIN/bin"
riscv_core_prepend_path "$RISCV_CORE_SURFER"

if [ -d "$RISCV_CORE_COCOTB_VENV/bin" ]; then
  riscv_core_prepend_path "$RISCV_CORE_COCOTB_VENV/bin"
  export VIRTUAL_ENV="$RISCV_CORE_COCOTB_VENV"
fi

export PATH
unset -f riscv_core_remove_path
unset -f riscv_core_prepend_path
