"""在当前 CPU 参数下比较 BRANCH、JAL、RET 三张独立预测表。"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import json
from itertools import product
from pathlib import Path

from dse.ras import fingerprint, read_result, replay


def storage_bits(config):
    """紧凑 RTL 可实现格式：BRANCH 保留 target bit1，JAL/RET 省掉 bit1。"""
    depth = config["depth"]
    ras = depth * (config["width"] - 2) + (depth - 1).bit_length() + depth.bit_length() if depth else 0
    bits = ras + 2 * config["bht_entries"]
    bits += config["sets"] * (config["ways"] - 1).bit_length()
    count = config["sets"] * config["ways"]
    tag = config["pc_bits"]
    if config["layout"] == "unified":
        kind = 2 if depth and config["mode"] == "btb" else 1
        bits += count * (1 + tag + 15 + kind)
    else:
        bits += count * (1 + tag + 15)
        jumps = config["jump_sets"] * config["jump_ways"]
        kind = int(bool(depth and config["mode"] == "btb"))
        bits += jumps * (1 + tag + 14 + kind)
        bits += config["jump_sets"] * (config["jump_ways"] - 1).bit_length()
    if depth and config["mode"] == "filter":
        size = config["filters"]
        ret_tag = config.get("ret_tag_bits", 0) or tag
        bits += size * (1 + ret_tag) + (size - 1).bit_length()
    return bits


def configurations(budget=360):
    base = dict(sets=1, ways=4, pc_bits=10, bht_entries=16, depth=1, width=16,
                mode="btb", filters=0, layout="split", jump_sets=1, jump_ways=2,
                priority="jump", ret_priority="ret", ret_tag_bits=0)
    points = [("current-b4-jr2-d1", base)]
    points.append(("old-unified4", {**base, "layout": "unified", "jump_sets": 0,
                                  "jump_ways": 0, "depth": 0}))
    points.append(("old-filter1", {**base, "layout": "unified", "jump_sets": 0,
                                 "jump_ways": 0, "mode": "filter", "filters": 1}))
    for branch, jump in ((4, 1), (4, 4), (8, 2), (2, 2)):
        points.append((f"shared-b{branch}-jr{jump}-d1", {**base, "ways": branch, "jump_ways": jump}))

    def triple(branch=4, jump=1, returns=1, **changes):
        return {**base, "ways": branch, "jump_ways": jump, "mode": "filter",
                "filters": returns, **changes}

    # 主网格保持 RAS1，独立分配三张表的容量。
    for branch in (1, 2, 4, 8):
        for jump in (1, 2, 4):
            for returns in (1, 2, 4, 8, 16):
                points.append((f"b{branch}-j{jump}-r{returns}-d1", triple(branch, jump, returns)))
    # 固定小表的栈深度对照，避免将识别容量收益归因于 RAS 深度。
    for jump, returns in ((1, 1), (1, 2), (1, 4), (2, 1), (2, 2), (2, 4), (4, 4)):
        for depth in (2, 4):
            points.append((f"b4-j{jump}-r{returns}-d{depth}", triple(4, jump, returns, depth=depth)))
    for jump, returns in ((1, 1), (1, 2), (2, 1), (2, 2), (4, 4)):
        points.append((f"b4-j{jump}-r{returns}-d1-p12", triple(4, jump, returns, pc_bits=12)))
        points.append((f"b4-j{jump}-r{returns}-d1-bsets2", triple(4, jump, returns, sets=2, ways=2)))
    for returns in (1, 4, 8):
        for sets in (2, 4):
            points.append((f"b4-j4-r{returns}-d1-jsets{sets}",
                           triple(4, 4, returns, jump_sets=sets, jump_ways=4 // sets)))
    for jump in (1, 2):
        for returns in (1, 2, 4):
            points.append((f"b4-j{jump}-r{returns}-d1-ret-last",
                           triple(4, jump, returns, ret_priority="btb")))
    # 只加宽 RET 标签，避免同时改变 JAL/BRANCH 的混叠与替换行为。
    for branch, jump, returns in ((4, 1, 1), (4, 1, 2), (4, 2, 2),
                                  (4, 4, 4), (4, 4, 8), (8, 2, 4)):
        for bits in (11, 12):
            points.append((f"b{branch}-j{jump}-r{returns}-d1-rp{bits}",
                           triple(branch, jump, returns, ret_tag_bits=bits)))
    return [(name, config) for name, config in points if storage_bits(config) <= budget]


def grid_configurations(budget=360, branches=(2, 4, 8), jals=(1, 2, 4),
                        returns=(1, 2, 4, 8), depths=(1, 2, 4), ret_bits=(10, 11, 12)):
    controls = [(name, config) for name, config in configurations(budget)
                if name in ("current-b4-jr2-d1", "old-unified4", "old-filter1")]
    base = controls[0][1]
    points = list(controls)
    for branch, jal, ret, depth, tag in product(dict.fromkeys(branches), dict.fromkeys(jals),
                                               dict.fromkeys(returns), dict.fromkeys(depths), dict.fromkeys(ret_bits)):
        config = {**base, "ways": branch, "jump_ways": jal, "mode": "filter",
                  "filters": ret, "depth": depth, "ret_tag_bits": tag}
        if storage_bits(config) <= budget:
            points.append((f"grid-b{branch}-j{jal}-r{ret}-d{depth}-rp{tag}", config))
    return points


def config_key(config):
    normalized = dict(config)
    normalized["ret_tag_bits"] = config.get("ret_tag_bits", 0) or config["pc_bits"]
    return json.dumps(normalized, sort_keys=True)


def load_cache(directory, provenance):
    """只复用同一轨迹和二进制的完整结果，逐点核对原始日志与 CSV 整数计数。"""
    saved = json.loads((directory / "inputs.json").read_text(encoding="utf-8"))
    for source in ("trace", "branchsim"):
        if any(saved[source][key] != provenance[source][key] for key in ("bytes", "sha256")):
            raise ValueError(f"reuse {source} fingerprint mismatch in {directory}")
    with (directory / "results.csv").open(encoding="utf-8", newline="") as stream:
        rows = {row["name"]: row for row in csv.DictReader(stream)}
    if set(rows) != set(saved["configurations"]):
        raise ValueError(f"incomplete reuse results in {directory}")
    cached = {}
    for name, config in saved["configurations"].items():
        log = directory / f"{name}.log"
        output = log.read_text(encoding="utf-8")
        parsed = read_result(output, (name, config))
        for key, value in parsed.items():
            if key == "instructions" or key.endswith(("_accesses", "_hits", "_misses")) or key in ("return_conflicts", "btb_conflicts", "direction_hits"):
                if int(rows[name][key]) != value:
                    raise ValueError(f"reuse log/CSV mismatch: {name} {key}")
        cached[config_key(config)] = output
    return cached


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--branchsim", type=Path, default=Path("build/branchsim"))
    parser.add_argument("--output", type=Path, default=Path("build/separate"))
    parser.add_argument("--ff-budget", type=int, default=360)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--grid", action="store_true", help="systematic microbench grid instead of the exploratory preset")
    parser.add_argument("--branch-entries", type=int, nargs="+", default=[2, 4, 8])
    parser.add_argument("--jal-entries", type=int, nargs="+", default=[1, 2, 4])
    parser.add_argument("--ret-entries", type=int, nargs="+", default=[1, 2, 4, 8])
    parser.add_argument("--ras-depths", type=int, nargs="+", default=[1, 2, 4])
    parser.add_argument("--ret-tag-bits", type=int, nargs="+", default=[10, 11, 12])
    parser.add_argument("--reuse-dir", type=Path, help="reuse verified points from the same trace and binary")
    parser.add_argument("--report-only", action="store_true", help="verify all saved points and regenerate exports")
    args = parser.parse_args()
    if args.jobs < 1 or args.ff_budget < 206:
        parser.error("jobs must be positive; ff-budget must include the 206-bit current baseline")
    sizes = args.branch_entries + args.jal_entries + args.ret_entries + args.ras_depths
    if any(n < 1 or n > 64 or n & (n - 1) for n in sizes):
        parser.error("entry counts and RAS depths must be powers of two <= 64")
    if any(n < 1 or n > 30 for n in args.ret_tag_bits):
        parser.error("RET tag width must be in [1, 30]")
    trace, binary = args.trace.resolve(), args.branchsim.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    provenance = {"trace": fingerprint(trace), "branchsim": fingerprint(binary)}
    points = (grid_configurations(args.ff_budget, args.branch_entries, args.jal_entries,
                                  args.ret_entries, args.ras_depths, args.ret_tag_bits)
              if args.grid else configurations(args.ff_budget))
    search = dict(grid=args.grid, branch_entries=args.branch_entries, jal_entries=args.jal_entries,
                  ret_entries=args.ret_entries, ras_depths=args.ras_depths, ret_tag_bits=args.ret_tag_bits,
                  ff_budget=args.ff_budget)
    cached = load_cache(args.output if args.report_only else args.reuse_dir, provenance) if args.report_only or args.reuse_dir else {}
    if args.report_only:
        saved = json.loads((args.output / "inputs.json").read_text())
        if saved.get("search") != search or saved["configurations"] != dict(points):
            raise ValueError("report-only scan parameters do not match saved results")
    results = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {}
        reused = 0
        for point in points:
            name, config = point
            output = cached.get(config_key(config))
            if output is not None:
                (args.output / f"{name}.log").write_text(output, encoding="utf-8")
                futures[pool.submit(read_result, output, point)] = point
                reused += 1
            elif args.report_only:
                raise ValueError(f"missing saved point: {name}")
            else:
                futures[pool.submit(replay, binary, trace, args.output, point)] = point
        print(f"planned={len(points)} reused={reused} replay={len(points)-reused}", flush=True)
        for future in as_completed(futures):
            row = future.result()
            if not row["instructions"]:
                raise ValueError("empty trace")
            row["compact_bits"] = storage_bits(futures[future][1])
            if args.grid:
                # 网页与 CSV 只保留当前紧凑成本，避免旧通用格式的位数混入横轴。
                row.pop("rtl_storage_bits")
            row["family"] = "triple" if row["layout"] == "split" and row["mode"] == "filter" else "control"
            # 三表的 RET 识别存储必须与真实 CLI 成本一致，不存在目标字段。
            if row["mode"] == "filter" and row["depth"]:
                size = row["filters"]
                expected = size * (row["return_tag_bits"] + 1) + (size - 1).bit_length()
                if row["return_table_bits"] != expected:
                    raise ValueError(f"{row['name']}: RET storage mismatch")
            results[row["name"]] = row
            print(f"{len(results)}/{len(points)} {row['name']}: {row['compact_bits']} bits, MPKI {row['mpki']:.6f}", flush=True)
    if provenance != {"trace": fingerprint(trace), "branchsim": fingerprint(binary)}:
        raise RuntimeError("input changed during sweep")
    rows = [results[name] for name, _ in points]
    baseline = rows[0]
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
    provenance.update(ff_budget=args.ff_budget, configurations=dict(points), search=search)
    (args.output / "inputs.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    lines = ["# Separate BRANCH / JAL / RET tables", "",
             f"Instructions: {baseline['instructions']:,}; current RTL configuration MPKI: {baseline['mpki']:.6f}.",
             "", "Costs use compact fields including aligned JAL targets. Default RET > JAL > BRANCH arbitration; all queries use PC only.",
             "", "## Best triple-table configuration under each budget", "",
             "| Budget | RAS1 config | Bits | MPKI | RAS1 miss reduction | Any tested RAS depth | Bits | MPKI |",
             "| ---: | --- | ---: | ---: | ---: | --- | ---: | ---: |"]
    for budget in (189, 201, 206, 215, 227, 250, 300, 360):
        if budget > args.ff_budget:
            continue
        candidates = [row for row in rows if row["family"] == "triple" and row["compact_bits"] <= budget]
        shallow = [row for row in candidates if row["depth"] == 1]
        if not shallow:
            continue
        first, best = [min(group, key=lambda row: (row["total_misses"], row["compact_bits"]))
                       for group in (shallow, candidates)]
        lines.append(f"| {budget} | {first['name']} | {first['compact_bits']} | {first['mpki']:.6f} | {first['miss_reduction_pct']:.3f}% | {best['name']} | {best['compact_bits']} | {best['mpki']:.6f} |")
    lines += ["", "## All points", "", "| Config | Bits | MPKI | Miss reduction vs current | BRANCH misses | JAL misses | RET misses | Ordinary misses | RET/BTB both hits |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in rows:
        lines.append(f"| {row['name']} | {row['compact_bits']} | {row['mpki']:.6f} | {row['miss_reduction_pct']:.3f}% | {row['branches_misses']:,} | {row['jals_misses']:,} | {row['returns_misses']:,} | {row['non_control_flow_misses']:,} | {row['return_conflicts']:,} |")
    lines += ["", f"Trace SHA-256: `{provenance['trace']['sha256']}`", f"Binary SHA-256: `{provenance['branchsim']['sha256']}`", ""]
    (args.output / "results.md").write_text("\n".join(lines), encoding="utf-8")
    if args.grid:
        from dse.separate_plot import write_plot
        write_plot(args.output / "dse.html", rows, provenance)


if __name__ == "__main__":
    main()
