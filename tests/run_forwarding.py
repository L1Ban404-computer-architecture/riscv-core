#!/usr/bin/env python3
"""Exercise forwarding priority and retention in both preprocessing modes."""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/forwarding-test'
BUILD.mkdir(parents=True, exist_ok=True)


def run(args, log):
    with log.open('w') as output:
        result = subprocess.run([str(arg) for arg in args], cwd=ROOT,
                                stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed; see {log}\n{log.read_text()[-6000:]}')


for mode, flags in [('simulation', []), ('synthesis', ['-DSYNTHESIS'])]:
    directory = BUILD / mode
    run([os.environ.get('VERILATOR', 'verilator'), '--cc', '--exe', '--build',
         '--sv', '--top-module', 'forwarding_tb', '--Mdir', directory, *flags,
         '-CFLAGS', '-std=c++17 -Wall -Wextra',
         'rtl/common/riscv_common_pkg.sv', 'rtl/core/riscv_core_pkg.sv',
         'rtl/core/riscv_core_if.sv', 'rtl/core/units/forwarding_unit.sv',
         'tests/forwarding_tb.sv', ROOT / 'tests/forwarding_test.cpp'],
        BUILD / f'{mode}.build.log')
    log = BUILD / f'{mode}.run.log'
    run([directory / 'Vforwarding_tb'], log)
    print(f'{mode}: {log.read_text().strip()}')
