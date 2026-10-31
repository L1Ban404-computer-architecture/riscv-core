"""固定当前 RTL 参数的小容量 RAS 对照，不改变原 BTB/BHT DSE 网格。"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import json
from pathlib import Path

from dse.results import fingerprint, replay
from dse.cost import predictor_bits


def configurations(depths, filters):
    base = dict(sets=1, ways=4, pc_bits=10, bht_entries=16,
                depth=0, width=16, mode="btb", filters=0)
    points = [("baseline", base)]
    # 以额外存储分别扩大方向表、标签和 BTB；为 RAS 提供机会成本对照。
    for name, changes in [("bht32", dict(bht_entries=32)),
                          ("p12", dict(pc_bits=12)),
                          ("btb8-s1", dict(ways=8)),
                          ("btb8-s2", dict(sets=2))]:
        points.append((name, {**base, **changes}))
    for depth in depths:
        for mode in ("btb", "ideal"):
            points.append((f"{mode}-d{depth}", {**base, "mode": mode, "depth": depth}))
        for size in filters:
            points.append((f"filter{size}-d{depth}",
                           {**base, "mode": "filter", "depth": depth, "filters": size}))
    # 确认低16位地址压缩是否损失收益；P12/16 检查 return 标签别名。
    if 4 in depths:
        for mode in ("btb", "ideal", "filter"):
            points.append((f"{mode}-d4-full32",
                           {**base, "depth": 4, "mode": mode, "width": 32,
                            "filters": 2 if mode == "filter" else 0}))
        for width in (12, 16):
            points.append((f"filter2-d4-p{width}",
                           {**base, "depth": 4, "mode": "filter", "filters": 2,
                            "pc_bits": width}))
    return points


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--branchsim", type=Path, default=Path("build/branchsim"))
    parser.add_argument("--output", type=Path, default=Path("build/ras"))
    parser.add_argument("--depths", type=int, nargs="+", default=[1, 2, 4, 8, 16])
    parser.add_argument("--filters", type=int, nargs="+", default=[1, 2, 4])
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1 or any(n < 1 or n > 64 or n & (n - 1) for n in args.depths + args.filters):
        parser.error("jobs must be positive; depths/filters must be powers of two <= 64")
    trace, binary = args.trace.resolve(), args.branchsim.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    provenance = {"trace": fingerprint(trace), "branchsim": fingerprint(binary)}
    points = configurations(list(dict.fromkeys(args.depths)), list(dict.fromkeys(args.filters)))
    results = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(replay, binary, trace, args.output, point): point[1] for point in points}
        for future in as_completed(futures):
            row = future.result()
            row["rtl_storage_bits"] = predictor_bits(futures[future])
            results[row["name"]] = row
            print(f"{len(results)}/{len(points)} {row['name']}: {row['rtl_storage_bits']} bits, MPKI {row['mpki']:.6f}", flush=True)
    if provenance != {"trace": fingerprint(trace), "branchsim": fingerprint(binary)}:
        raise RuntimeError("input changed during sweep")
    rows = [results[name] for name, _ in points]
    baseline = rows[0]
    for row in rows:
        for group in ("instructions", "control_flow_accesses", "non_control_flow_accesses",
                      "returns_accesses", "other_jalr_accesses", "branches_accesses", "jals_accesses"):
            if row[group] != baseline[group]:
                raise ValueError(f"{row['name']}: input population mismatch")
        row["saved_misses"] = baseline["total_misses"] - row["total_misses"]
        row["miss_reduction_pct"] = 100 * row["saved_misses"] / baseline["total_misses"] if baseline["total_misses"] else 0
    with (args.output / "results.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    provenance["commands"] = {name: config for name, config in points}
    (args.output / "inputs.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    summary = ["# RAS replay", "", f"Instructions: {baseline['instructions']:,}; baseline misses: {baseline['total_misses']:,}.",
               "", "Storage uses current RTL compact fields plus RAS/classifier state; ideal omits classification cost.",
               "", "| Config | Bits | MPKI | Miss reduction | Return hits | Ordinary misses |",
               "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for row in rows:
        summary.append(f"| {row['name']} | {row['rtl_storage_bits']} | {row['mpki']:.6f} | {row['miss_reduction_pct']:.3f}% | {row['returns_hits']:,} | {row['non_control_flow_misses']:,} |")
    summary += ["", "Input SHA-256:", "", f"- trace: `{provenance['trace']['sha256']}`",
                f"- branchsim: `{provenance['branchsim']['sha256']}`", ""]
    (args.output / "results.md").write_text("\n".join(summary), encoding="utf-8")


if __name__ == "__main__":
    main()
