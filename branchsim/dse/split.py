"""扫描独立 BRANCH BTB 与共享 JAL/RET BTB，比较固定存储预算下的收益。"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import json
from pathlib import Path

from dse.results import fingerprint, replay
from dse.cost import predictor_bits as storage_bits


def configurations(budget=360):
    base = dict(sets=1, ways=4, pc_bits=10, bht_entries=16, depth=0, width=16,
                mode="btb", filters=0, layout="unified", jump_sets=0, jump_ways=0, priority="jump")
    points = [("baseline", base)]
    for ways in (2, 4, 8):
        for depth in (0, 1, 2, 4):
            if ways == 4 and depth == 0:
                continue
            points.append((f"unified{ways}-d{depth}", {**base, "ways": ways, "depth": depth}))
    for size in (1, 2, 4):
        for depth in (1, 2):
            points.append((f"filter{size}-d{depth}",
                           {**base, "mode": "filter", "filters": size, "depth": depth}))
    for branch in (1, 2, 4, 8):
        for jump in (1, 2, 4, 8):
            for depth in (0, 1, 2, 4):
                config = {**base, "layout": "split", "ways": branch, "jump_sets": 1,
                          "jump_ways": jump, "depth": depth}
                points.append((f"b{branch}-j{jump}-d{depth}", config))
                if depth == 2:
                    points.append((f"b{branch}-j{jump}-d2-branch-first", {**config, "priority": "branch"}))
    # 加宽两张表的标签，检查仲裁损失是否来自 P10 混叠。
    for branch, jump in ((2, 2), (4, 2), (2, 4)):
        for bits in (12, 16):
            points.append((f"b{branch}-j{jump}-d2-p{bits}",
                           {**base, "layout": "split", "ways": branch, "jump_sets": 1,
                            "jump_ways": jump, "depth": 2, "pc_bits": bits}))
    return [(name, config) for name, config in points if storage_bits(config) <= budget]


def set_configurations(budget=360):
    """固定 4 项 BRANCH、2/4 项 JAL/RET，区分 RR 容量干扰与组索引干扰。"""
    base = configurations()[0][1]
    points = [("baseline", base)]
    for jumps in (2, 4):
        for branch_sets in (1, 2):
            for jump_sets in ((1, 2) if jumps == 2 else (1, 2, 4)):
                for depth in (0, 2):
                    config = {**base, "layout": "split", "sets": branch_sets,
                              "ways": 4 // branch_sets, "jump_sets": jump_sets,
                              "jump_ways": jumps // jump_sets, "depth": depth}
                    points.append((f"b4-j{jumps}-bs{branch_sets}-js{jump_sets}-d{depth}", config))
    return [(name, config) for name, config in points if storage_bits(config) <= budget]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--branchsim", type=Path, default=Path("build/branchsim"))
    parser.add_argument("--output", type=Path, default=Path("build/split"))
    parser.add_argument("--ff-budget", type=int, default=360)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--set-sweep", action="store_true", help="focused set-associativity check at fixed capacity")
    args = parser.parse_args()
    if args.jobs < 1 or args.ff_budget < 142:
        parser.error("jobs must be positive; ff-budget must be at least 142 for the baseline")
    trace, binary = args.trace.resolve(), args.branchsim.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    provenance = {"trace": fingerprint(trace), "branchsim": fingerprint(binary)}
    points = (set_configurations if args.set_sweep else configurations)(args.ff_budget)
    results = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(replay, binary, trace, args.output, point): point for point in points}
        for future in as_completed(futures):
            row = future.result()
            row["rtl_storage_bits"] = storage_bits(futures[future][1])
            if not row["instructions"]:
                raise ValueError("empty trace")
            results[row["name"]] = row
            print(f"{len(results)}/{len(points)} {row['name']}: {row['rtl_storage_bits']} bits, MPKI {row['mpki']:.6f}", flush=True)
    if provenance != {"trace": fingerprint(trace), "branchsim": fingerprint(binary)}:
        raise RuntimeError("input changed during sweep")
    rows = [results[name] for name, _ in points]
    baseline = results["baseline"]
    for row in rows:
        for field in ("instructions", "control_flow_accesses", "non_control_flow_accesses",
                      "returns_accesses", "other_jalr_accesses", "branches_accesses", "jals_accesses"):
            if row[field] != baseline[field]:
                raise ValueError(f"{row['name']}: input population mismatch")
        row["saved_misses"] = baseline["total_misses"] - row["total_misses"]
        row["miss_reduction_pct"] = 100 * row["saved_misses"] / baseline["total_misses"] if baseline["total_misses"] else 0
    with (args.output / "results.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    provenance.update(ff_budget=args.ff_budget, set_sweep=args.set_sweep, configurations=dict(points))
    (args.output / "inputs.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    lines = ["# Split BTB replay", "", f"Instructions: {baseline['instructions']:,}; baseline MPKI: {baseline['mpki']:.6f}.",
             "", "P10/T16, Bimodal[16], RR unless specified. Bits count predictor storage; lower MPKI is better.",
             "", "## Best under each budget", "",
             "| Budget | Unified / separate RET filter | Bits | MPKI | Split | Bits | MPKI |",
             "| ---: | --- | ---: | ---: | --- | ---: | ---: |"]
    for budget in (142, 168, 196, 219, 252, 307, 360):
        if budget > args.ff_budget:
            continue
        candidates = [row for row in rows if row["rtl_storage_bits"] <= budget]
        groups = [[row for row in candidates if row["layout"] == layout] for layout in ("unified", "split")]
        if any(not group for group in groups):
            continue
        left, right = [min(group, key=lambda row: (row["total_misses"], row["rtl_storage_bits"])) for group in groups]
        lines.append(f"| {budget} | {left['name']} | {left['rtl_storage_bits']} | {left['mpki']:.6f} | {right['name']} | {right['rtl_storage_bits']} | {right['mpki']:.6f} |")
    lines += ["", "## All points", "", "| Config | Bits | MPKI | Miss reduction | BRANCH misses | JAL misses | RET misses | Ordinary misses | Both-hit queries |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in rows:
        lines.append(f"| {row['name']} | {row['rtl_storage_bits']} | {row['mpki']:.6f} | {row['miss_reduction_pct']:.3f}% | {row['branches_misses']:,} | {row['jals_misses']:,} | {row['returns_misses']:,} | {row['non_control_flow_misses']:,} | {row['btb_conflicts']:,} |")
    lines += ["", f"Trace SHA-256: `{provenance['trace']['sha256']}`", f"Binary SHA-256: `{provenance['branchsim']['sha256']}`", ""]
    (args.output / "results.md").write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
