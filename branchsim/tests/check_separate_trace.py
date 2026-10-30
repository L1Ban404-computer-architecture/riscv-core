"""Real CLI coverage for separate BRANCH, JAL and target-free RET tables."""

import csv
from pathlib import Path
import subprocess
import sys
import tempfile

from check_alias_trace import jal, replay
from dse.separate import config_key, configurations, grid_configurations, storage_bits


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(dir=binary.parent, prefix="check-separate-") as work:
        directory = Path(work)
        call = (0x1000, jal(0x1100) | 0x80, 0x2100, 0x2100, 2, 1)
        ret = (0x2100, 0x8067, 0x1004, 0x1004, 3, 1)
        branch = (0x1004, 0xfe000ee3, 0x1000, 0x1000, 1, 1)
        records = [call, ret, branch] * 3
        common = ["--bht", "bimodal", "--bht-entries", "16", "--ras-entries", "1",
                  "--btb-layout", "split", "--jump-btb-ways", "1"]
        shared = replay(binary, directory, records, pc_bits=10, ways=1, extra=common)
        separate_args = [*common, "--ras-mode", "filter", "--ras-filter-entries", "1"]
        separate = replay(binary, directory, records, pc_bits=10, ways=1, extra=separate_args)
        assert int(shared["total"]["misses"]) == 7
        assert int(separate["total"]["misses"]) == 3
        for group in ("branches", "jals", "returns"):
            assert int(separate[group]["hits"]) == 2
        assert int(separate["return_table"]["storage_bits"]) == 11
        assert int(separate["return_table"]["conflicts"]) == 0
        # A JAL and a RET have the same partial tag in different tables.
        alias_call = (0x1000, jal(0x1000) | 0x80, 0x2000, 0x2000, 2, 1)
        alias_ret = (0x2000, 0x8067, 0x1004, 0x1004, 3, 1)
        for priority, ret_hits, jal_hits in (("ret", 2, 0), ("btb", 0, 2)):
            result = replay(binary, directory, [alias_call, alias_ret, branch] * 3,
                            pc_bits=10, ways=1, extra=[*separate_args, "--ret-priority", priority])
            assert int(result["total"]["misses"]) == 5
            assert int(result["returns"]["hits"]) == ret_hits
            assert int(result["jals"]["hits"]) == jal_hits
            assert int(result["return_table"]["conflicts"]) == 4
        full = replay(binary, directory, [alias_call, alias_ret, branch] * 3,
                      pc_bits=12, ways=1, extra=separate_args)
        assert int(full["total"]["misses"]) == 3
        wide_ret = replay(binary, directory, [alias_call, alias_ret, branch] * 3,
                          pc_bits=10, ways=1, extra=[*separate_args, "--ras-filter-pc-bits", "11"])
        assert int(wide_ret["total"]["misses"]) == 3
        assert int(wide_ret["return_table"]["storage_bits"]) == 12
        assert int(wide_ret["return_table"]["tag_bits"]) == 11
        ordinary = (0x3100, 0x13, 0x3104, 0, 0, 0)
        result = replay(binary, directory, [call, ret, branch, call, ordinary],
                        pc_bits=10, ways=1, extra=separate_args)
        assert int(result["non_control_flow"]["misses"]) == 1
        # Use the legal loop for the complete budgeted study.
        replay(binary, directory, records, pc_bits=10, ways=1, extra=separate_args)
        points = dict(configurations())
        assert storage_bits(points["current-b4-jr2-d1"]) == 206
        assert storage_bits(points["b4-j1-r1-d1"]) == 189
        assert storage_bits(points["b4-j1-r2-d1"]) == 201
        assert all(storage_bits(config) <= 360 for config in points.values())
        subprocess.run([sys.executable, "-m", "dse.separate", "--trace", str(directory / "trace.bin"),
                        "--branchsim", str(binary), "--output", str(directory / "study"),
                        "--ff-budget", "206", "--jobs", "2"],
                       check=True, stdout=subprocess.PIPE, text=True)
        with (directory / "study/results.csv").open() as stream:
            rows = list(csv.DictReader(stream))
        assert len(rows) == len(configurations(206))
        assert all(int(row["compact_bits"]) <= 206 for row in rows)
        assert "current RTL configuration" in (directory / "study/results.md").read_text()
        grid = grid_configurations()
        assert len(grid) == 250 and len({config_key(config) for _, config in grid}) == 250
        assert all(storage_bits(config) <= 360 for _, config in grid)
        grid_command = [sys.executable, "-m", "dse.separate", "--grid", "--trace", str(directory / "trace.bin"),
                        "--branchsim", str(binary), "--output", str(directory / "grid"),
                        "--ff-budget", "206", "--jobs", "2"]
        subprocess.run(grid_command, check=True, stdout=subprocess.PIPE, text=True)
        html = directory / "grid/dse.html"
        original = html.read_bytes()
        assert b'__PAYLOAD__' not in original and b'id="dse-data"' in original
        with (directory / "grid/results.csv").open() as stream:
            assert len(list(csv.DictReader(stream))) == len(grid_configurations(206))
        subprocess.run([*grid_command, "--report-only"], check=True, stdout=subprocess.PIPE, text=True)
        assert html.read_bytes() == original
        # A source/config mismatch must preserve the previously published interactive page.
        log = directory / "grid/current-b4-jr2-d1.log"
        log.write_text(log.read_text().replace("btb_sets=1", "btb_sets=2"))
        failed = subprocess.run([*grid_command, "--report-only"], capture_output=True, text=True)
        assert failed.returncode != 0 and "wrong predictor config" in failed.stderr
        assert html.read_bytes() == original
    print("PASS: triple-table isolation, RET priority, aliases, compact costs and budgeted sweep")


if __name__ == "__main__":
    main()
