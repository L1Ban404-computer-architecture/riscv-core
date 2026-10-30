"""Check split BTBs using a call/return/branch loop and the budgeted CLI sweep."""

import csv
from pathlib import Path
import subprocess
import sys
import tempfile

from check_alias_trace import jal, replay
from dse.split import configurations, set_configurations, storage_bits


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(dir=binary.parent, prefix="check-split-") as work:
        directory = Path(work)
        call = (0x1000, jal(0x1100) | 0x80, 0x2100, 0x2100, 2, 1)
        ret = (0x2100, 0x8067, 0x1004, 0x1004, 3, 1)
        branch = (0x1004, 0xfe000ee3, 0x1000, 0x1000, 1, 1)
        records = [call, ret, branch] * 3
        common = ["--bht", "bimodal", "--bht-entries", "16", "--ras-entries", "2"]
        unified = replay(binary, directory, records, pc_bits=10, ways=2, extra=common)
        assert int(unified["total"]["misses"]) == 9
        split = replay(binary, directory, records, pc_bits=10, ways=1,
                       extra=[*common, "--btb-layout", "split", "--jump-btb-ways", "2"])
        assert int(split["total"]["misses"]) == 3
        assert int(split["returns"]["hits"]) == 2
        assert int(split["branches"]["hits"]) == 2
        assert int(split["jals"]["hits"]) == 2
        assert split["btb_layout"] == dict(mode="split", jump_sets="1", jump_ways="2",
                                          priority="jump", conflicts="0")
        mapped = replay(binary, directory, records, pc_bits=10, ways=1,
                        extra=[*common, "--btb-layout", "split", "--jump-btb-sets", "2",
                               "--jump-btb-ways", "1"])
        assert int(mapped["total"]["misses"]) == 7
        no_ras = replay(binary, directory, records, pc_bits=10, ways=1,
                        extra=["--bht", "bimodal", "--btb-layout", "split"])
        assert int(no_ras["total"]["misses"]) == 5
        invalid = subprocess.run([str(binary), "--trace", str(directory / "trace.bin"),
                                  "--btb-layout", "split", "--ras-mode", "ideal"],
                                 capture_output=True, text=True)
        assert invalid.returncode == 2 and "split layout requires" in invalid.stderr
        points = dict(configurations())
        assert storage_bits(points["baseline"]) == 142
        assert storage_bits(points["b2-j2-d2"]) == 171
        assert storage_bits(points["b4-j2-d2"]) == 224
        assert all(storage_bits(config) <= 360 for config in points.values())
        set_points = dict(set_configurations())
        assert len(set_points) == 21
        assert storage_bits(set_points["b4-j4-bs1-js4-d2"]) == 277
        subprocess.run([sys.executable, "-m", "dse.split", "--trace", str(directory / "trace.bin"),
                        "--branchsim", str(binary), "--output", str(directory / "study"),
                        "--ff-budget", "142", "--jobs", "2"],
                       check=True, stdout=subprocess.PIPE, text=True)
        with (directory / "study/results.csv").open() as stream:
            rows = list(csv.DictReader(stream))
        assert len(rows) == len(configurations(142))
        assert all(int(row["rtl_storage_bits"]) <= 142 for row in rows)
        assert "Best under each budget" in (directory / "study/results.md").read_text()
    print("PASS: split BTB isolation, RAS ablation, CLI validation and budgeted sweep")


if __name__ == "__main__":
    main()
