# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

"""扫描边界、计数校验与真实模拟器的端到端检查。"""

import contextlib
import csv
import io
import os
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dse import FF_BUDGET, FULL_PC_ENTRY_BITS
from dse.__main__ import BRANCHSIM_DIR, geometries, main, parse_args, parse_output, replay, storage_bits
from dse.report import best_by_capacity, pareto


class SweepTests(unittest.TestCase):
    def test_geometries_and_equivalent_points(self):
        args = parse_args([])
        self.assertEqual((args.entries_min, args.entries_max, args.ways_max), (1, None, None))
        self.assertEqual((args.bht, args.policies), (["btfn"], ["rr"]))
        self.assertEqual(args.ff_budget, 8 * FULL_PC_ENTRY_BITS)
        points = geometries(args.entries_min, args.entries_max, args.ways_max, args.bht,
                            args.policies, args.pc_bits, args.target_bits, args.ff_budget)
        self.assertEqual(len(points), 141)
        self.assertEqual(len(points), len(set(points)))
        self.assertEqual(sum(point[1] == "none" for point in points), 1)
        self.assertIn(("btfn", "table", 2, 2, "rr", 8, 16, 0), points)
        expected = {("btfn", "table", sets, ways, "rr", p, t, 0)
                    for sets in (1, 2, 4, 8, 16, 32) for ways in (2, 4, 8, 16, 32)
                    for p in (4, 8, 16, 30) for t in (4, 8, 16, 32)
                    if sets * ways * (p + t + 3) + sets * (ways - 1).bit_length() <= FF_BUDGET}
        self.assertEqual({point for point in points if point[1] == "table"}, expected)
        self.assertEqual(len({(point[2], point[3]) for point in expected}), 15)
        for _, btb, sets, ways, policy, pc_bits, target_bits, bht_entries in points:
            if btb == "none":
                continue
            self.assertTrue(2 <= sets * ways <= 32)
            self.assertEqual(sets & (sets - 1), 0)
            self.assertGreaterEqual(ways, 2)
            self.assertEqual(ways & (ways - 1), 0)
            self.assertEqual(policy, "rr")
            self.assertLessEqual(storage_bits(("btfn", btb, sets, ways, policy, pc_bits, target_bits))["total_ff"], FF_BUDGET)
            self.assertIn(pc_bits, (4, 8, 16, 30))
            self.assertIn(target_bits, (4, 8, 16, 32))
        self.assertIn(("btfn", "table", 2, 2, "lru", 8, 16, 0),
                      geometries(4, 4, 2, ["btfn", "btfn"], ["lru", "lru"]))
        with self.assertRaises(ValueError):
            geometries(1, None, None, ["btfn"], ["rr"], ff_budget=FF_BUDGET + 1)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parse_args(["--ff-budget", str(FF_BUDGET + 1)])
        for flag, value in (("--pc-bits", "2"), ("--pc-bits", "12"), ("--pc-bits", "32"),
                            ("--target-bits", "2"), ("--target-bits", "12"), ("--target-bits", "33"),
                            ("--ways-max", "1")):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                parse_args([flag, value])

    def test_budget_includes_replacement_and_allows_more_entries(self):
        points = geometries(1, None, None, ["btfn"], ["rr", "lru"], [8, 30], [16, 32])
        self.assertNotIn(("btfn", "table", 1, 8, "rr", 30, 32, 0), points)  # 523
        self.assertIn(("btfn", "table", 1, 16, "rr", 8, 16, 0), points)  # 436
        self.assertNotIn(("btfn", "table", 1, 32, "rr", 8, 16, 0), points)
        compact = geometries(1, None, None, ["btfn"], ["rr", "lru"], [4], [8])
        self.assertIn(("btfn", "table", 1, 32, "rr", 4, 8, 0), compact)  # 485
        self.assertNotIn(("btfn", "table", 1, 32, "lru", 4, 8, 0), compact)  # 640
        narrow = geometries(1, None, None, ["btfn"], ["rr"], [8], [16], ff_budget=110)
        self.assertIn(("btfn", "table", 1, 4, "rr", 8, 16, 0), narrow)
        self.assertTrue(all(storage_bits(point)["total_ff"] <= 110 for point in narrow))
        below = geometries(1, None, None, ["btfn"], ["rr"], [8], [16], ff_budget=109)
        self.assertNotIn(("btfn", "table", 1, 4, "rr", 8, 16, 0), below)

    def test_flip_flop_accounting(self):
        self.assertEqual(storage_bits(("btfn", "table", 2, 4, "rr", 8, 16, 0)),
                         {"entry_bits": 27, "replacement_bits": 4, "btb_ff": 220, "bht_ff": 0, "total_ff": 220})
        self.assertEqual(storage_bits(("btfn", "table", 2, 4, "lru", 8, 16, 0)),
                         {"entry_bits": 27, "replacement_bits": 16, "btb_ff": 232, "bht_ff": 0, "total_ff": 232})
        self.assertEqual(storage_bits(("btfn", "table", 1, 3, "rr", 8, 16, 0))["total_ff"], 83)
        self.assertEqual(storage_bits(("btfn", "table", 4, 1, "rr", 8, 16, 0))["replacement_bits"], 0)
        self.assertEqual(storage_bits(("not-taken", "none", 1, 1, "rr", 0, 0, 0))["total_ff"], 0)

    def test_bimodal_storage_and_budget(self):
        point = ("bimodal", "table", 2, 4, "rr", 16, 16, 32)
        self.assertEqual(storage_bits(point), {"entry_bits": 35, "replacement_bits": 4,
                                              "btb_ff": 284, "bht_ff": 64, "total_ff": 348})
        points = geometries(1, None, None, ["btfn", "bimodal"], ["rr"], [8], [16],
                            bht_entries=[16, 32, 64])
        self.assertEqual(len(points), len(set(points)))
        self.assertIn(("bimodal", "table", 1, 16, "rr", 8, 16, 32), points)  # 500 bits
        self.assertNotIn(("bimodal", "table", 1, 16, "rr", 8, 16, 64), points)  # 564 bits
        self.assertTrue(all(storage_bits(item)["total_ff"] <= FF_BUDGET for item in points))
        self.assertTrue(all(item[7] == 0 for item in points if item[0] == "btfn"))
        with self.assertRaises(ValueError):
            storage_bits(("bimodal", "table", 2, 4, "rr", 16, 16))
        with self.assertRaises(ValueError):
            storage_bits(("bimodal", "table", 2, 4, "rr", 16, 16, 0))
        for value in ("0", "3"):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                parse_args(["--bht-entries", value])

    def test_bimodal_learns_forward_branch_through_trace(self):
        offset = (-8) & ((1 << 21) - 1)
        jump = (((offset >> 20) & 1) << 31 | ((offset >> 1) & 0x3ff) << 21 |
                ((offset >> 11) & 1) << 20 | ((offset >> 12) & 0xff) << 12 | 0x6f)
        records = []
        for i in range(10):
            records.append(struct.pack("<QIIIIBB", 2 * i + 1, 0x1000, 0x463, 0x1008, 0x1008, 1, 1))
            records.append(struct.pack("<QIIIIBB", 2 * i + 2, 0x1008, jump, 0x1000, 0x1000, 2, 1))
        self.trace.write_bytes(self.header + b"".join(records))
        dynamic = self.run_point(("bimodal", "table", 1, 2, "rr", 30, 32, 4))
        static = self.run_point(("btfn", "table", 1, 2, "rr", 30, 32, 0))
        self.assertEqual(dynamic["total_misses"], 2)  # Only the first branch and JAL are cold.
        self.assertEqual(static["total_misses"], 11)
        self.assertEqual(dynamic["bht_ff"], 8)
        self.assertEqual(dynamic["total_ff"] - static["total_ff"], 8)

    def test_pareto_equal_capacity_and_ties(self):
        rows = [{"entries": 4, "total_ff": bits, "total_misses": misses, "bht": "btfn",
                 "btb_ways": 1, "btb_policy": "rr", "pc_bits": 8, "target_bits": 16}
                for bits, misses in ((0, 20), (64, 15), (64, 16), (128, 15), (256, 10))]
        self.assertEqual([(row["total_ff"], row["total_misses"]) for row in pareto(rows)],
                         [(0, 20), (64, 15), (256, 10)])

    def test_single_way_is_candidate_for_both_policies(self):
        rows = [{"entries": 4, "total_misses": misses, "bht": "btfn", "btb": "table",
                 "btb_ways": ways, "btb_policy": policy, "pc_bits": 8, "target_bits": 16,
                 "total_ff": 108}
                for ways, policy, misses in ((1, "rr", 5), (2, "rr", 6), (2, "lru", 7))]
        best = best_by_capacity(rows)
        self.assertEqual(len(best), 2)
        self.assertTrue(all(row["btb_ways"] == 1 for row in best))
        self.assertTrue(next(row for row in best if row["btb_policy"] == "lru")["equivalent"])

    def setUp(self):
        self.binary = Path(os.environ.get("BRANCHSIM", BRANCHSIM_DIR / "build" / "branchsim"))
        build = BRANCHSIM_DIR / "build"
        build.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=build, prefix="check-dse-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.trace = self.work / "trace.bin"
        self.header = struct.pack("<4sHHHBBIQ", b"ITRC", 1, 24, 26, 32, 4, 16, 0)
        # 两次 JAL 自环：首次冷缺失，第二次命中。not-taken BHT 也应预测 JAL。
        self.records = b"".join(struct.pack("<QIIIIBB", i, 0x1000, 0x6f, 0x1000, 0x1000, 2, 1)
                                for i in (1, 2))
        self.trace.write_bytes(self.header + self.records)

    def run_point(self, point=("btfn", "table", 4, 1, "rr", 8, 16, 0)):
        return replay(self.binary, self.trace, self.work, point)

    def test_jal_predictions_and_integer_metrics(self):
        row = self.run_point(("not-taken", "table", 4, 1, "rr", 8, 16, 0))
        self.assertEqual(row["instructions"], 2)
        self.assertEqual(row["total_hits"], 1)
        self.assertEqual(row["total_misses"], 1)
        self.assertEqual(row["mpki"], 500)
        self.assertEqual(row["actual_not_taken_hit_rate"], "-")
        log = (self.work / "not-taken_table_s4_w1_rr_p8_t16.log").read_text()
        # 单组计数看似自洽，但与总数的分区不一致，必须拒绝。
        bad = log.replace("actual_taken accesses=2 hits=1 misses=1",
                          "actual_taken accesses=3 hits=1 misses=2")
        with self.assertRaises(ValueError):
            parse_output(bad)

    def test_alias_false_prediction_on_ordinary_instruction(self):
        # JAL +0x400 后执行 NOP：两条 PC 的低八个字地址位相同。
        jump = struct.pack("<QIIIIBB", 1, 0x1000, 0x4000006f, 0x1400, 0x1400, 2, 1)
        ordinary = struct.pack("<QIIIIBB", 2, 0x1400, 0x13, 0x1404, 0, 0, 0)
        self.trace.write_bytes(self.header + jump + ordinary)
        partial = self.run_point(("btfn", "table", 1, 1, "rr", 8, 16, 0))
        full = self.run_point(("btfn", "table", 1, 1, "rr", 30, 32, 0))
        self.assertEqual(partial["total_accesses"], 2)
        self.assertEqual(partial["control_flow_misses"], 1)
        self.assertEqual(partial["non_control_flow_misses"], 1)
        self.assertEqual(partial["mpki"], 1000)
        self.assertEqual(full["non_control_flow_misses"], 0)
        self.assertEqual(full["mpki"], 500)

    def test_truncated_target_preserves_direction_but_counts_wrong_target(self):
        # 后向 BEQ 跨越 64 KiB 边界，再由 JAL 返回。拼接后的目标位于前方，
        # 方向仍应使用训练时保存的 backward，而不是重算拼接目标的方向。
        backward = struct.pack("<QIIIIBB", 1, 0x10000, 0xfe000ee3, 0xfffc, 0xfffc, 1, 1)
        back = struct.pack("<QIIIIBB", 2, 0xfffc, 0x0040006f, 0x10000, 0x10000, 2, 1)
        again = struct.pack("<QIIIIBB", 3, 0x10000, 0xfe000ee3, 0xfffc, 0xfffc, 1, 1)
        self.trace.write_bytes(self.header + backward + back + again)
        partial = self.run_point(("btfn", "table", 1, 2, "rr", 30, 16, 0))
        full = self.run_point(("btfn", "table", 1, 2, "rr", 30, 32, 0))
        self.assertEqual(partial["direction_hits"], 1)
        self.assertEqual(partial["total_hits"], 0)
        self.assertEqual(partial["total_misses"], 3)
        self.assertEqual(full["direction_hits"], 1)
        self.assertEqual(full["total_hits"], 1)
        self.assertEqual(full["total_misses"], 2)

    def test_empty_and_corrupt_trace(self):
        self.trace.write_bytes(self.header)
        row = self.run_point()
        self.assertEqual(row["mpki"], "-")
        self.assertEqual(row["total_hit_rate"], "-")
        self.trace.write_bytes(self.header + self.records[:-1])
        with self.assertRaises(RuntimeError):
            self.run_point()

    def test_full_sweep_report_and_failure(self):
        args = ["--branchsim", str(self.binary), "--trace", str(self.trace),
                "--build-dir", str(self.work), "--entries-min", "4", "--entries-max", "4",
                "--ways-max", "2", "--pc-bits", "8", "--target-bits", "16", "--jobs", "2"]
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(args), 0)
        with (self.work / "dse.csv").open() as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(len(rows), 2)
        self.assertEqual(sorted(int(row["total_misses"]) for row in rows), [1, 2])
        page = (self.work / "dse.html").read_text()
        self.assertNotIn("__ROWS__", page)
        self.assertIn("<svg", page)
        summary = (self.work / "dse.md").read_text()
        self.assertIn("SHA-256", summary)
        with contextlib.redirect_stderr(io.StringIO()), patch("dse.__main__.subprocess.run",
                                                             side_effect=AssertionError("unexpected replay")):
            self.assertEqual(main(args + ["--report-only"]), 0)
        log = self.work / "dse" / "logs" / "btfn_table_s2_w2_rr_p8_t16.log"
        original_log = log.read_text()
        log.write_text(original_log.replace("pc_bits=8", "pc_bits=7"))
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaisesRegex(RuntimeError, "config"):
            main(args + ["--report-only"])
        log.write_text(original_log)
        original = (self.work / "dse.csv").read_bytes()
        self.trace.write_bytes(b"invalid")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaisesRegex(RuntimeError, "fingerprint mismatch"):
            main(args + ["--report-only"])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError):
            main(args)
        self.assertEqual((self.work / "dse.csv").read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
