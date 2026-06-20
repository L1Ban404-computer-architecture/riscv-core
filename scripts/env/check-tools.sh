#!/usr/bin/env sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/riscv-core-env.sh"

failures=0

check_cmd() {
  name=$1
  shift

  printf '%-32s' "$name"
  if command -v "$name" >/dev/null 2>&1; then
    printf 'OK  %s\n' "$(command -v "$name")"
    "$@" || failures=$((failures + 1))
  else
    printf 'FAIL  not found\n'
    failures=$((failures + 1))
  fi
}

print_version_line() {
  "$@" 2>&1 | sed -n '1p'
}

echo "RISCV_CORE_TOOLS=$RISCV_CORE_TOOLS"
echo "PATH=$PATH"
echo

check_cmd verilator print_version_line verilator --version
check_cmd yosys print_version_line yosys -V
check_cmd sby print_version_line sby --version
check_cmd slang-server print_version_line slang-server --version
check_cmd riscv64-unknown-elf-gcc print_version_line riscv64-unknown-elf-gcc --version
check_cmd riscv64-unknown-elf-objcopy print_version_line riscv64-unknown-elf-objcopy --version
check_cmd surfer print_version_line surfer --version
check_cmd surver print_version_line surver --version
check_cmd python print_version_line python --version

printf '%-32s' "python cocotb import"
if cocotb_version=$(python -c 'import cocotb; print(cocotb.__version__)' 2>/tmp/riscv-core-cocotb-check.err); then
  printf 'OK  cocotb %s\n' "$cocotb_version"
else
  printf 'FAIL\n'
  sed -n '1,5p' /tmp/riscv-core-cocotb-check.err
  failures=$((failures + 1))
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "All stage-0 tool checks passed."
else
  echo "$failures stage-0 tool check(s) failed."
fi

exit "$failures"
