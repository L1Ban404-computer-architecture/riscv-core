# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

"""在同一条退休指令轨迹上扫描小容量 BTB 的几何、策略与 PC 位宽。"""

from __future__ import annotations

import argparse
import csv
import hashlib
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

from dse import BHT_ENTRIES, FF_BUDGET, PC_WIDTHS, TARGET_WIDTHS
from dse.report import CSV_FIELDS, GROUPS, sort_key, write_csv, write_plot, write_summary

BRANCHSIM_DIR = Path(__file__).resolve().parents[1]
Point = Tuple[str, str, int, int, str, int, int, int]


def powers_of_two(limit: int) -> List[int]:
    values = []
    value = 1
    while value <= limit:
        values.append(value)
        value *= 2
    return values


def geometries(entries_min: int, entries_max: int | None, ways_max: int | None,
               bhts: Sequence[str], policies: Sequence[str],
               pc_bits: Sequence[int] = PC_WIDTHS, target_bits: Sequence[int] = TARGET_WIDTHS,
               ff_budget: int = FF_BUDGET, bht_entries: Sequence[int] = BHT_ENTRIES) -> List[Point]:
    if (entries_min < 1 or (entries_max is not None and entries_max < entries_min)
            or (ways_max is not None and ways_max < 2) or not 0 < ff_budget <= FF_BUDGET):
        raise ValueError(f"invalid bounds; require 0 < ff-budget <= {FF_BUDGET}, ways-max >= 2")
    if not pc_bits or any(bits not in PC_WIDTHS for bits in pc_bits):
        raise ValueError(f"pc-bits must be selected from {PC_WIDTHS}")
    if not target_bits or any(bits not in TARGET_WIDTHS for bits in target_bits):
        raise ValueError(f"target-bits must be selected from {TARGET_WIDTHS}")
    if not bht_entries or any(n < 1 or (n & (n - 1)) != 0 for n in bht_entries):
        raise ValueError("bht-entries must be positive powers of two")
    # 关闭 BTB 时所有 BHT/几何都等价，只保留一个始终不跳转的基线。
    points = [(bhts[0], "none", 1, 2, "rr", 0, 0, 0)]
    # 扫描只取二次幂组数和路数，启用 BTB 时至少两路。
    # 按最窄表项推导有限枚举上界；每个实际位宽/策略再核算替换状态。
    limit = ff_budget // (min(pc_bits) + min(target_bits) + 3)
    if entries_max is not None:
        limit = min(limit, entries_max)
    for sets in powers_of_two(limit):
        for ways in powers_of_two(min(limit // sets, ways_max or limit)):
            if ways < 2 or sets * ways < entries_min:
                continue
            for bht in dict.fromkeys(bhts):
                for policy in dict.fromkeys(policies):
                    for pc_width in dict.fromkeys(pc_bits):
                        for target_width in dict.fromkeys(target_bits):
                            sizes = dict.fromkeys(bht_entries) if bht == "bimodal" else (0,)
                            for size in sizes:
                                point = (bht, "table", sets, ways, policy, pc_width, target_width, size)
                                if storage_bits(point)["total_ff"] <= ff_budget:
                                    points.append(point)
    return points


def point_name(point: Point) -> str:
    bht, btb, sets, ways, policy, pc_bits, target_bits = point[:7]
    size = point[7] if len(point) == 8 else 0
    suffix = f"_h{size}" if size else ""
    return f"{bht}_{btb}_s{sets}_w{ways}_{policy}_p{pc_bits}_t{target_bits}{suffix}"


def storage_bits(point: Point) -> Dict[str, int]:
    """设计声明的触发器位数；软件容器大小不参与硬件成本。"""
    bht, btb, sets, ways, policy, pc_bits, target_bits = point[:7]
    if btb == "none":
        return {"entry_bits": 0, "replacement_bits": 0, "btb_ff": 0, "bht_ff": 0, "total_ff": 0}
    if bht == "bimodal" and (len(point) != 8 or point[7] < 1 or (point[7] & (point[7] - 1)) != 0):
        raise ValueError("bimodal point requires a positive power-of-two BHT size")
    entries = sets * ways
    # 每项除两个 PC 字段外，还有 valid、分支类型和原始前后向各一位。
    entry_bits = pc_bits + target_bits + 3
    replacement_bits = (sets if policy == "rr" else entries) * (ways - 1).bit_length()
    btb_ff = entries * entry_bits + replacement_bits
    bht_ff = 2 * point[7] if bht == "bimodal" else 0
    return {"entry_bits": entry_bits, "replacement_bits": replacement_bits,
            "btb_ff": btb_ff, "bht_ff": bht_ff, "total_ff": btb_ff + bht_ff}


def parse_output(output: str) -> Dict[str, object]:
    """用整数计数重算比率，避免把模拟器打印的六位小数当作原始精度。"""
    lines = {}
    instructions = None
    for line in output.splitlines():
        cells = line.split()
        if not cells:
            continue
        if cells[0].startswith("instructions="):
            instructions = int(cells[0].split("=", 1)[1])
        elif cells[0] in (*GROUPS, "direction"):
            if cells[0] in lines:
                raise ValueError(f"duplicate statistics: {cells[0]}")
            lines[cells[0]] = dict(cell.split("=", 1) for cell in cells[1:])
    if instructions is None or instructions < 0:
        raise ValueError("missing/invalid instruction count")
    row: Dict[str, object] = {"instructions": instructions}
    for group in GROUPS:
        counts = lines[group]
        accesses, hits, misses = (int(counts[key]) for key in ("accesses", "hits", "misses"))
        if min(accesses, hits, misses) < 0 or hits + misses != accesses:
            raise ValueError(f"inconsistent {group} counts")
        row.update({f"{group}_accesses": accesses, f"{group}_hits": hits,
                    f"{group}_misses": misses,
                    f"{group}_hit_rate": hits / accesses if accesses else "-"})
    accesses = int(row["total_accesses"])
    hits = int(row["total_hits"])
    if accesses != instructions:
        raise ValueError("total observations must include every retired instruction")
    for pair in (("actual_taken", "actual_not_taken"),
                 ("predicted_taken", "predicted_not_taken"),
                 ("control_flow", "non_control_flow")):
        for metric in ("accesses", "hits", "misses"):
            if sum(int(row[f"{group}_{metric}"]) for group in pair) != row[f"total_{metric}"]:
                raise ValueError(f"inconsistent {pair} partition")
    direction_hits = int(lines["direction"]["hits"])
    if not hits <= direction_hits <= accesses:
        raise ValueError("inconsistent direction hits")
    row["direction_hits"] = direction_hits
    row["direction_hit_rate"] = direction_hits / accesses if accesses else "-"
    row["mpki"] = 1000 * int(row["total_misses"]) / instructions if instructions else "-"
    return row


def replay(branchsim: Path, trace: Path, log_dir: Path, point: Point) -> Dict[str, object]:
    bht, btb, sets, ways, policy, pc_bits, target_bits = point[:7]
    command = [str(branchsim), "--trace", str(trace), "--bht", bht, "--btb", btb,
               "--btb-sets", str(sets), "--btb-ways", str(ways), "--btb-policy", policy]
    if btb != "none":
        command.extend(["--pc-bits", str(pc_bits), "--target-bits", str(target_bits)])
    if bht == "bimodal" and btb != "none":
        command.extend(["--bht-entries", str(point[7])])
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    log = log_dir / f"{point_name(point)}.log"
    log.write_text(completed.stdout, encoding="utf-8")
    if completed.returncode:
        raise RuntimeError(f"{point_name(point)} exited {completed.returncode}; see {log}")
    return read_result(log, point)


def read_result(log: Path, point: Point) -> Dict[str, object]:
    bht, btb, sets, ways, policy, pc_bits, target_bits = point[:7]
    size = point[7] if len(point) == 8 else 0
    output = log.read_text(encoding="utf-8")
    try:
        configs = [dict(cell.split("=", 1) for cell in line.split()[1:])
                   for line in output.splitlines() if line.startswith("config ")]
        expected = {"bht": bht, "btb": btb, "btb_sets": str(sets),
                    "btb_ways": str(ways), "btb_policy": policy,
                    "bht_entries": str(size), "bht_ff": str(storage_bits(point)["bht_ff"])}
        if btb != "none":
            expected.update(pc_bits=str(pc_bits), target_bits=str(target_bits))
        if len(configs) != 1 or any(configs[0].get(key) != value for key, value in expected.items()):
            raise ValueError("config does not match requested point")
        parsed = parse_output(output)
    except (KeyError, ValueError) as error:
        raise RuntimeError(f"invalid result in {log}: {error}") from error
    return {"bht": bht, "btb": btb, "btb_sets": sets, "btb_ways": ways,
            "btb_policy": policy, "entries": sets * ways if btb == "table" else 0,
            "pc_bits": pc_bits, "target_bits": target_bits, "bht_entries": size,
            **storage_bits(point), **parsed}


def verified_report_rows(build_dir: Path, points: Sequence[Point], provenance: dict) -> List[dict]:
    """只重建完整旧报告：校验输入记录、计划、原始日志及每个 CSV 字段。"""
    summary = (build_dir / "dse.md").read_text(encoding="utf-8")
    saved = re.findall(r"- (trace|branchsim): `([^`]+)`\n  - bytes: (\d+)\n  - SHA-256: `([0-9a-f]{64})`", summary)
    if len(saved) != 2 or {item[0] for item in saved} != {"trace", "branchsim"}:
        raise RuntimeError("report-only requires complete input fingerprints in dse.md")
    for name, _, size, digest in saved:
        if (int(size), digest) != (provenance[name]["bytes"], provenance[name]["sha256"]):
            raise RuntimeError(f"report-only {name} fingerprint mismatch; rerun the sweep")
    with (build_dir / "dse.csv").open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != list(CSV_FIELDS):
            raise RuntimeError("report-only CSV schema mismatch; rerun the sweep")
        saved_rows = list(reader)
    remaining = set(points)
    rows = []
    for saved_row in saved_rows:
        point = (saved_row["bht"], saved_row["btb"], int(saved_row["btb_sets"]),
                 int(saved_row["btb_ways"]), saved_row["btb_policy"],
                 int(saved_row["pc_bits"]), int(saved_row["target_bits"]), int(saved_row["bht_entries"]))
        if point not in remaining:
            raise RuntimeError("report-only CSV contains unexpected or duplicate configurations")
        remaining.remove(point)
        row = read_result(build_dir / "dse" / "logs" / f"{point_name(point)}.log", point)
        if any(saved_row[key] != str(row[key]) for key in CSV_FIELDS):
            raise RuntimeError(f"report-only CSV disagrees with raw log: {point_name(point)}")
        rows.append(row)
    if remaining:
        raise RuntimeError(f"report-only CSV is missing {len(remaining)} configurations")
    return rows


def fingerprint(path: Path) -> dict:
    before = path.stat()
    with path.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise RuntimeError(f"input changed while hashing: {path}")
    return {"path": str(path), "bytes": after.st_size, "mtime_ns": after.st_mtime_ns,
            "sha256": digest}


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=BRANCHSIM_DIR / "build")
    parser.add_argument("--branchsim", type=Path)
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--entries-min", type=int, default=1)
    parser.add_argument("--entries-max", type=int, help="optional additional entry-count cap")
    parser.add_argument("--ways-max", type=int, help="optional associativity cap (>=2; candidates are powers of two)")
    parser.add_argument("--ff-budget", type=int, default=FF_BUDGET,
                        help=f"total logical FF limit, including replacement state (1..{FF_BUDGET})")
    parser.add_argument("--bht", nargs="+", choices=("not-taken", "btfn", "bimodal"),
                        default=["bimodal"])
    parser.add_argument("--bht-entries", nargs="+", type=int, default=list(BHT_ENTRIES),
                        help="bimodal counter counts (positive powers of two); ignored by static strategies")
    parser.add_argument("--policies", nargs="+", choices=("rr", "lru"), default=["rr"])
    parser.add_argument("--pc-bits", nargs="+", type=int, default=list(PC_WIDTHS),
                        help="PC tag widths: 8, 12, 16, or 20")
    parser.add_argument("--target-bits", nargs="+", type=int, default=list(TARGET_WIDTHS),
                        help="target low-bit widths: 8, 12, 16, 20, or 24")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument("--report-only", action="store_true",
                        help="verify existing CSV, raw logs and input hashes; rebuild reports without replay")
    args = parser.parse_args(argv)
    if (args.entries_min < 1 or (args.entries_max is not None and args.entries_max < args.entries_min)
            or (args.ways_max is not None and args.ways_max < 2) or args.jobs < 1
            or not 0 < args.ff_budget <= FF_BUDGET):
        parser.error(f"invalid bounds; require 0 < ff-budget <= {FF_BUDGET}, ways-max >= 2, jobs >= 1")
    if any(bits not in PC_WIDTHS for bits in args.pc_bits):
        parser.error(f"pc-bits must be selected from {PC_WIDTHS}")
    if any(bits not in TARGET_WIDTHS for bits in args.target_bits):
        parser.error(f"target-bits must be selected from {TARGET_WIDTHS}")
    if any(n < 1 or (n & (n - 1)) != 0 for n in args.bht_entries):
        parser.error("bht-entries must be positive powers of two")
    args.build_dir = args.build_dir.resolve()
    args.branchsim = (args.branchsim or args.build_dir / "branchsim").resolve()
    args.trace = (args.trace or args.build_dir / "runner-insttrace.bin").resolve()
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    points = geometries(args.entries_min, args.entries_max, args.ways_max, args.bht,
                        args.policies, args.pc_bits, args.target_bits, args.ff_budget, args.bht_entries)
    if len(points) == 1:
        raise RuntimeError("no valid BTB geometries in requested interval")
    # 记录确切输入；回放后检查文件没有被同时采集/重编译所改动。
    provenance = {"trace": fingerprint(args.trace), "branchsim": fingerprint(args.branchsim),
                  "search": {"ff_budget": args.ff_budget, "bht": args.bht,
                             "policies": args.policies, "pc_bits": args.pc_bits,
                             "bht_entries": args.bht_entries,
                             "target_bits": args.target_bits, "ways_min": 2,
                             "power_of_two_geometry": True}}
    log_dir = args.build_dir / "dse" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    if args.report_only:
        rows = verified_report_rows(args.build_dir, points, provenance)
        print(f"verified {len(rows)} completed configs; rebuild reports", file=sys.stderr)
    else:
        print(f"sweep {len(points)} configs, jobs={args.jobs} -> {args.build_dir}/dse.*", file=sys.stderr)
        # 先串行跑基线，损坏的轨迹只诊断一次。
        rows = [replay(args.branchsim, args.trace, log_dir, points[0])]
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = {pool.submit(replay, args.branchsim, args.trace, log_dir, point): point
                       for point in points[1:]}
            for index, future in enumerate(as_completed(futures), start=2):
                rows.append(future.result())
                print(f"[{index}/{len(points)}] {point_name(futures[future])}", file=sys.stderr)
    for source in (provenance["trace"], provenance["branchsim"]):
        current = Path(source["path"]).stat()
        if (current.st_size, current.st_mtime_ns) != (source["bytes"], source["mtime_ns"]):
            raise RuntimeError(f"input changed during sweep: {source['path']}")
    for metric in ("instructions", "total_accesses", "control_flow_accesses", "non_control_flow_accesses",
                   "actual_taken_accesses", "actual_not_taken_accesses"):
        if len({row[metric] for row in rows}) != 1:
            raise RuntimeError(f"inconsistent {metric} across configurations")
    rows.sort(key=sort_key)
    # 所有点成功后才发布本轮报告；失败日志保留供排查。
    staged = []
    for suffix, writer in (("csv", write_csv), ("html", write_plot), ("md", write_summary)):
        path = args.build_dir / f"dse.{suffix}"
        temporary = path.with_suffix(path.suffix + ".tmp")
        writer(temporary, rows, provenance)
        staged.append((temporary, path))
    for temporary, path in staged:
        temporary.replace(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
