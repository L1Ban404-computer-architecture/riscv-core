# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

"""Exercise partial-tag redirects through the real retired-trace CLI."""

import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def jal(offset):
    value = offset & ((1 << 21) - 1)
    return (((value >> 20) & 1) << 31 | ((value >> 1) & 0x3ff) << 21 |
            ((value >> 11) & 1) << 20 | ((value >> 12) & 0xff) << 12 | 0x6f)


def replay(binary, directory, records, pc_bits=8, target_bits=16, ways=1):
    trace = directory / "trace.bin"
    header = struct.pack("<4sHHHBBIQ", b"ITRC", 1, 24, 26, 32, 4, 16, 0)
    trace.write_bytes(header + b"".join(struct.pack("<QIIIIBB", i, *record)
                                      for i, record in enumerate(records, 1)))
    result = subprocess.run([str(binary), "--trace", str(trace), "--btb-sets", "1",
                             "--btb-ways", str(ways), "--pc-bits", str(pc_bits),
                             "--target-bits", str(target_bits)],
                            check=True, text=True, stdout=subprocess.PIPE)
    lines = {}
    for line in result.stdout.splitlines():
        cells = line.split()
        if cells and cells[0] in ("total", "control_flow", "non_control_flow", "direction"):
            lines[cells[0]] = dict(cell.split("=", 1) for cell in cells[1:])
    lines["instructions"] = re.search(r"instructions=(\d+) mpki=(\S+)", result.stdout).groups()
    return lines


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(dir=binary.parent, prefix="check-alias-") as work:
        directory = Path(work)
        # A JAL lands on an ordinary instruction with the same PC[9:2] tag.
        records = [(0x1000, jal(0x400), 0x1400, 0x1400, 2, 1),
                   (0x1400, 0x13, 0x1404, 0, 0, 0)]
        partial = replay(binary, directory, records)
        assert int(partial["total"]["accesses"]) == 2
        assert int(partial["total"]["misses"]) == 2
        assert int(partial["control_flow"]["accesses"]) == 1
        assert int(partial["non_control_flow"]["misses"]) == 1
        assert partial["instructions"] == ("2", "1000.000000")
        full = replay(binary, directory, records, 30, 32)
        assert int(full["non_control_flow"]["misses"]) == 0
        assert full["instructions"] == ("2", "500.000000")

        # Revisit a direct jump crossing a 64 KiB boundary. The direction is
        # right on the third retirement, but the 16-bit spliced target is wrong.
        a, b = 0x1000fffc, 0x10010000
        records = [(a, jal(4), b, b, 2, 1),
                   (b, jal(-4), a, a, 2, 1),
                   (a, jal(4), b, b, 2, 1)]
        partial = replay(binary, directory, records, ways=2)
        assert int(partial["direction"]["hits"]) == 1
        assert int(partial["total"]["hits"]) == 0
        assert partial["instructions"] == ("3", "1000.000000")
        full = replay(binary, directory, records, 30, 32, ways=2)
        assert int(full["total"]["hits"]) == 1
        assert full["instructions"] == ("3", "666.666667")
    print("PASS: trace CLI includes ordinary false redirects and wrong reconstructed targets")


if __name__ == "__main__":
    main()
