"""Real CLI: cold return classification, aliases, compressed targets and the study report."""

import csv
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from check_alias_trace import jal, replay


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(dir=binary.parent, prefix="check-ras-") as work:
        directory = Path(work)
        call = (0x1000, jal(0x1100) | 0x80, 0x2100, 0x2100, 2, 1)
        ret = (0x2100, 0x8067, 0x1004, 0x1004, 3, 1)
        nop = (0x1004, 0x13, 0x1000, 0, 0, 0)
        records = [call, ret, nop] * 3
        for mode, misses, hits in (("btb", 2, 2), ("filter", 2, 2), ("ideal", 1, 3)):
            result = replay(binary, directory, records, pc_bits=10, ways=4,
                            extra=["--ras-entries", "2", "--ras-mode", mode])
            assert int(result["total"]["misses"]) == misses
            assert int(result["returns"]["hits"]) == hits
            assert int(result["redirects"]["count"]) == misses
            assert int(result["ras"]["available"]) == 3
            assert int(result["ras"]["underflows"]) == 0
        baseline = replay(binary, directory, records, pc_bits=10, ways=4)
        assert int(baseline["total"]["misses"]) == 4
        assert int(baseline["ras"]["storage_bits"]) == 0

        # RV32E rejects rd=x16. The ideal oracle must honor the validated kind,
        # even though the raw JALR encoding contains a return hint.
        illegal_return = (0x2200, 0x8867, 0x2204, 0, 0, 0)
        result = replay(binary, directory, [call, illegal_return], pc_bits=10, ways=4,
                        extra=["--ras-entries", "2", "--ras-mode", "ideal"])
        assert int(result["non_control_flow"]["hits"]) == 1
        assert int(result["ras"]["predictions"]) == 0

        alias = (0x3100, 0x13, 0x3104, 0, 0, 0)
        for mode in ("btb", "filter"):
            result = replay(binary, directory, [call, ret, nop, call, alias], pc_bits=10,
                            ways=4, extra=["--ras-entries", "2", "--ras-mode", mode])
            assert int(result["non_control_flow"]["misses"]) == 1

        a, b = 0x1000fff8, 0x10010004
        records = [(a, jal(b-a) | 0x80, b, b, 2, 1),
                   (b, 0x8067, a+4, a+4, 3, 1)] * 2
        for width, return_hits in ((16, 0), (32, 1)):
            result = replay(binary, directory, records, pc_bits=10, ways=4,
                            extra=["--ras-entries", "2", "--ras-target-bits", str(width)])
            assert int(result["returns"]["hits"]) == return_hits

        # A disabled baseline remains identical to the old model even when mode is ideal.
        disabled = replay(binary, directory, records, pc_bits=10, ways=4,
                          extra=["--ras-mode", "ideal"])
        assert int(disabled["ras"]["predictions"]) == 0
        result = subprocess.run([str(binary), "--trace", str(directory / "trace.bin"),
                                 "--ras-entries", "3"], capture_output=True, text=True)
        assert result.returncode == 2 and "ras-entries" in result.stderr
        subprocess.run([sys.executable, "-m", "dse.ras", "--trace", str(directory / "trace.bin"),
                        "--branchsim", str(binary), "--output", str(directory / "study"),
                        "--depths", "1", "2", "--filters", "1", "--jobs", "2"],
                       check=True, stdout=subprocess.PIPE, text=True)
        with (directory / "study/results.csv").open() as stream:
            rows = list(csv.DictReader(stream))
        assert len(rows) == 11 and rows[0]["rtl_storage_bits"] == "142"
        assert len(json.loads((directory / "study/inputs.json").read_text())["trace"]["sha256"]) == 64
        assert "ideal-d2" in (directory / "study/results.md").read_text()
    print("PASS: RAS CLI classification, alias, address width, disable and reproducible sweep")


if __name__ == "__main__":
    main()
