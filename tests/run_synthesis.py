#!/usr/bin/env python3
"""Check source-level pruning, lowered hardware, and cycle-exact bus behavior."""
import difflib
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/synthesis-test'
BUILD.mkdir(parents=True, exist_ok=True)
VERILATOR = os.environ.get('VERILATOR', 'verilator')
YOSYS = os.environ.get('YOSYS', 'yosys')


def run(args, log):
    with log.open('w') as output:
        result = subprocess.run([str(x) for x in args], cwd=ROOT,
                                stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed; see {log}\n{log.read_text()[-6000:]}')


# Read all sources explicitly so preprocessing also covers library-only modules.
sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'rtl').rglob('*.sv'))
preprocessed = BUILD / 'synthesis.preprocessed.sv'
run([VERILATOR, '-E', '-P', '-DSYNTHESIS', '-Irtl', *sources], preprocessed)
forbidden = re.compile(
    r'\b(?:instid\w*|debug_retire\w*|debug_perf\w*|core_retire_valid|'
    r'retire_debug\w*|performance_\w*|memory_performance_stats|'
    r'u_performance_stats|u_imem_stats|u_dmem_stats|retire_mem\w*|'
    r'retire_redirect\w*|csr_state_if)\b')
# Comments describe the simulation feature even when its implementation is gone.
source = re.sub(r'/\*.*?\*/|//[^\n]*', '', preprocessed.read_text(), flags=re.S)
assert not forbidden.search(source), forbidden.search(source)

lowered = BUILD / 'rtl.v'
run([YOSYS, '-Q', '-T', '-p',
     'plugin -i slang; read_slang -D SYNTHESIS --single-unit --ignore-assertions '
     '-f .slang/riscv_core.f; proc; bwmuxmap; write_verilog ' + str(lowered)],
    BUILD / 'yosys.log')
assert not forbidden.search(lowered.read_text()), 'Observation logic survived lowering'
assert 'mtime_q' in lowered.read_text(), 'Functional CLINT timer was removed'

common = [VERILATOR, '--cc', '--exe', '--build', '--assert', '--sv', '-Irtl',
          '-y', 'rtl/common', '-y', 'rtl/core', '-y', 'rtl/core/pipeline',
          '-y', 'rtl/core/units', '--top-module', 'synthesis_core_tb',
          '-Wno-PINCONNECTEMPTY', '-CFLAGS', '-std=c++17 -UNDEBUG',
          'rtl/common/riscv_common_pkg.sv', 'rtl/bus/riscv_bus_pkg.sv',
          'rtl/core/riscv_core_pkg.sv', 'rtl/bus/riscv_bus_if.sv',
          'rtl/core/riscv_core_if.sv', 'tests/synthesis_core_tb.sv',
          ROOT / 'tests/synthesis_core_test.cpp']
traces = []
for mode, flags in [('simulation', []), ('synthesis', ['-DSYNTHESIS'])]:
    directory = BUILD / mode
    run([*common, *flags, '--Mdir', directory], BUILD / f'{mode}.build.log')
    trace = BUILD / f'{mode}.trace'
    run([directory / 'Vsynthesis_core_tb'], trace)
    traces.append(trace.read_text().splitlines())
assert len(traces[0]) == 3600, 'Incomplete functional trace'
assert traces[0] == traces[1], '\n'.join(difflib.unified_diff(*traces))
print('SYNTHESIS pruning and 3600-cycle functional comparison: PASS')
