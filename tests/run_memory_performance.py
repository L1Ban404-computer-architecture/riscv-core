#!/usr/bin/env python3
"""Check independent memory event aggregation and both performance reporters."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/memory-performance-test'
BUILD.mkdir(parents=True, exist_ok=True)


def run(args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


run(['verilator', '--binary', '--timing', '--assert', '--top-module',
     'memory_performance_tb', '-Wno-TIMESCALEMOD', '-Irtl', '--Mdir', BUILD,
     'rtl/common/riscv_common_pkg.sv', 'rtl/bus/riscv_bus_pkg.sv',
     'rtl/core/riscv_core_pkg.sv', 'rtl/bus/riscv_bus_if.sv',
     'rtl/core/pipeline/memory_performance_stats.sv', 'tests/memory_performance_tb.sv'])
run([BUILD / 'Vmemory_performance_tb'])
outputs = []
for name, component, report, flags in [
    ('npc', 'mini-soc', 'rtl', []),
    ('soc', 'ysyx-soc', 'verilator', ['-DSOC']),
]:
    src = ROOT.parent / component / 'src'
    binary = BUILD / f'report-{name}'
    run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror', *flags,
         '-I' + str(src), 'tests/memory_performance_report_test.cpp',
         src / report / 'performance_report.cpp', '-o', binary])
    outputs.append(subprocess.check_output([str(binary)], cwd=ROOT))
assert outputs[0] == outputs[1], 'Performance log formats differ'
print('Memory performance RTL and both reporters: PASS')
