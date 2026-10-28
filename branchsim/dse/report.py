# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

"""保存完整计数、触发器–MPKI 散点页和 Pareto 摘要。"""

from __future__ import annotations

import csv
import json
import math
from html import escape
from pathlib import Path
from typing import Dict, Sequence

from dse import FF_BUDGET, FULL_PC_ENTRY_BITS, REFERENCE_ENTRIES

GROUPS = ("total", "control_flow", "non_control_flow", "actual_taken", "actual_not_taken",
          "predicted_taken", "predicted_not_taken")
CSV_FIELDS = ("bht", "btb", "btb_sets", "btb_ways", "btb_policy", "entries", "pc_bits", "target_bits",
              "bht_entries", "entry_bits", "replacement_bits", "btb_ff", "bht_ff", "total_ff", "instructions",
              *(f"{group}_{metric}" for group in GROUPS
                for metric in ("accesses", "hits", "misses", "hit_rate")),
              "direction_hits", "direction_hit_rate", "mpki")
_TEMPLATE = Path(__file__).with_name("plot.html")
FIELDS = ("bht", "btb_policy", "btb_sets", "btb_ways", "entries", "pc_bits", "target_bits", "bht_entries")
FIELD_LABELS = {"bht": "方向策略", "btb_policy": "替换策略", "btb_sets": "组数",
                "btb_ways": "路数", "entries": "表项数", "pc_bits": "原 PC 位宽",
                "target_bits": "目标 PC 位宽", "bht_entries": "BHT 计数器数"}
_PALETTE = ("#2563eb", "#d97706", "#059669", "#dc2626", "#7c3aed", "#0891b2", "#db2777", "#4f46e5", "#65a30d")
_SHAPES = ("circle", "square", "triangle", "diamond", "plus", "down", "hexagon", "cross", "star")
_W, _H = 960, 600
_LEFT, _RIGHT, _TOP, _BOTTOM = 78, 26, 28, 68


def sort_key(row: Dict[str, object]) -> tuple:
    return (int(row["total_misses"]), int(row.get("total_ff", row["entries"])),
            str(row["bht"]), int(row["btb_ways"]), str(row["btb_policy"]),
            int(row.get("pc_bits", 30)), int(row.get("target_bits", 32)), int(row.get("bht_entries", 0)))


def label(row: dict) -> str:
    if row["btb"] == "none":
        return "关闭 BTB"
    widths = f" / PC{row['pc_bits']}→目标{row['target_bits']}" if "pc_bits" in row else ""
    equivalent = "（单路等价）" if row.get("equivalent") else ""
    method = f"{row['bht']}[{row['bht_entries']}]" if row.get("bht_entries") else str(row["bht"])
    return f"{method} / {row['btb_sets']}组×{row['btb_ways']}路 / {row['btb_policy']}{widths}{equivalent}"


def fmt(value: object, percent: bool = False) -> str:
    if value == "-":
        return "—"
    return f"{float(value) * 100:.4f}%" if percent else f"{float(value):.6f}"


def write_csv(path: Path, rows: Sequence[dict], provenance: dict) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(CSV_FIELDS))
        writer.writeheader()
        writer.writerows(rows)


def best_by_capacity(rows: Sequence[dict]) -> list[dict]:
    """保留容量摘要接口；不同位宽只取同容量误预测最低的一项。"""
    best = {}
    policies = {row["btb_policy"] for row in rows if row["btb"] == "table"}
    for row in sorted(rows, key=sort_key):
        if row["btb"] == "table":
            candidates = policies if row["btb_ways"] == 1 else (row["btb_policy"],)
            for policy in candidates:
                equivalent = ({**row, "btb_policy": policy, "equivalent": True}
                              if policy != row["btb_policy"] else row)
                best.setdefault((row["entries"], row["bht"], policy), equivalent)
    return sorted(best.values(), key=lambda r: (int(r["entries"]), str(r["bht"]), str(r["btb_policy"])))


def pareto(rows: Sequence[dict]) -> list[dict]:
    """两个目标均最小化；同一成本只保留最低误预测，重合坐标取一个代表。"""
    best_misses = float("inf")
    front = []
    for row in sorted(rows, key=lambda r: (int(r.get("total_ff", r["entries"])), sort_key(r))):
        if row.get("mpki") == "-":
            continue
        if int(row["total_misses"]) < best_misses:
            front.append(row)
            best_misses = int(row["total_misses"])
    return front


def table(rows: Sequence[dict]) -> str:
    lines = ["| 配置 | BTB表项 | BTB位数 | BHT位数 | 总触发器 | 完整命中率 | 控制流误预测 | 普通指令假跳转 | MPKI |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in rows:
        lines.append(f"| {label(row)} | {row['entries']} | {row['btb_ff']} | {row['bht_ff']} | {row['total_ff']} | "
                     f"{fmt(row['total_hit_rate'], True)} | {row['control_flow_misses']} | "
                     f"{row['non_control_flow_misses']} | {fmt(row['mpki'])} |")
    return "\n".join(lines)


def write_summary(path: Path, rows: Sequence[dict], provenance: dict) -> None:
    budget = provenance.get("search", {}).get("ff_budget", FF_BUDGET)
    baseline = next(row for row in rows if row["btb"] == "none")
    best = min(rows, key=sort_key)
    selected = [baseline]
    # 同几何比较用户示例与完整宽度，避免把几何和位宽的收益混为一谈。
    for widths in ((8, 16), (30, 32)):
        candidates = [row for row in rows if row["btb"] == "table" and row["bht"] == "btfn"
                      and row["btb_policy"] == "rr" and (row["btb_sets"], row["btb_ways"]) == (1, 4)
                      and (row["pc_bits"], row["target_bits"]) == widths]
        if candidates:
            selected.append(min(candidates, key=sort_key))
    if best not in selected:
        selected.append(best)
    geometries = {(row["btb_sets"], row["btb_ways"]) for row in rows if row["btb"] == "table"}
    text = ["# Branchsim 位宽与几何扫描", "",
            f"扫描 {len(rows)} 个配置、{len(geometries)} 种几何，BTB 与 BHT 合计不超过 {budget} 个逻辑触发器（含替换状态）。每个配置从空表开始，回放同一条完整轨迹。",
            "组数与路数均为 2 的整数幂，路数至少为 2。两个位宽最小为 4，原 PC 的 30 位为完整标签特例。",
            f"完整 PC 参考条目为 30 + 32 + 3 = {FULL_PC_ENTRY_BITS} 位，资源上限为 {REFERENCE_ENTRIES} 个完整条目，即 {FF_BUDGET} 位。表项数随位宽和几何变化。",
            f"退休指令 **{baseline['instructions']:,}** 条；控制流 **{baseline['control_flow_accesses']:,}** 条；"
            f"普通指令 **{baseline['non_control_flow_accesses']:,}** 条。", "",
            "## 关键配置", "", table(selected), ""]
    if baseline["total_misses"]:
        reduction = 1 - int(best["total_misses"]) / int(baseline["total_misses"])
        text.extend([f"最低 MPKI 配置为 {label(best)}，占 {best['total_ff']} 个逻辑触发器；"
                     f"相对关闭 BTB，误预测减少 {reduction:.2%}。", ""])
    methods = sorted({str(row["bht"]) for row in rows if row["btb"] == "table"},
                     key=lambda method: (method != "btfn", method))
    best_methods = [min((row for row in rows if row["btb"] == "table" and row["bht"] == method),
                        key=sort_key) for method in methods]
    text.extend(["## 相同总预算下各算法最优配置", "", table(best_methods), ""])
    if "btfn" in methods and "bimodal" in methods:
        bf, bm = (next(row for row in best_methods if row["bht"] == name) for name in ("btfn", "bimodal"))
        change = 1 - int(bm["total_misses"]) / int(bf["total_misses"]) if bf["total_misses"] else 0
        text.extend([f"在同一 {budget} 位总预算内，Bimodal 最优配置相对 BTFN 最优配置的误预测减少 {change:.2%}。", ""])
    fixed = sorted((row for row in rows if row["btb"] == "table" and row["btb_policy"] == "rr"
                    and (row["btb_sets"], row["btb_ways"], row["pc_bits"], row["target_bits"]) == (1, 4, 30, 32)),
                   key=lambda row: (row["bht"] != "btfn", row["bht"], row["bht_entries"]))
    if fixed:
        text.extend(["## 固定 BTB 几何与位宽的算法对照", "",
                     "以下固定 1 组 4 路、原 PC 30 位、目标 32 位，单独比较方向预测；动态算法额外计入 BHT 存储。", "",
                     table(fixed), ""])
    text.extend(["## 触发器与 MPKI 的 Pareto 前沿", "",
                 "两个目标均越小越好。以下每个坐标保留一个代表配置；相同坐标的其他配置见 CSV 或图表悬停。", "",
                 table(pareto(rows)), "", "## 存储与统计口径", "",
                 "- 默认 BTFN/RR；原 PC 位宽扫描 4/8/16/30，目标位宽扫描 4/8/16/32；关闭 BTB 作为独立零成本基线。",
                 "- 原 PC 位宽 P 存储并比较 `(pc >> 2)` 的低 P 位，组索引仍是 `(pc >> 2) & (sets - 1)`；训练匹配也使用截断标签。",
                 "- 目标位宽 T 存储目标 PC 的低 T 位；查询目标为当前 PC 高 `32-T` 位与所存低 T 位拼接。T=32 时保存完整目标。",
                 "- BTFN 的后向标志由完整原 PC/目标 PC 在训练时计算并保存，目标截断不会改变方向规则。",
                 "- BTB 位数 = 表项数 × (P + T + 3) + 替换状态位。额外 3 位是 valid、分支/JAL 类型、backward；各算法保留相同 BTB 格式。",
                 "- Bimodal 使用 PC 字地址低位索引 M 个二位饱和计数器，初始为弱不跳转 01，按真实条件分支 taken 更新，预测在训练前发生。",
                 "- Bimodal 的 BHT 位数为 2 × M；BTFN/not-taken 为 0。总逻辑触发器 = BTB 位数 + BHT 位数，统一受预算限制。",
                 "- RR 替换状态位 = 组数 × ceil(log2(路数))；LRU = 表项数 × ceil(log2(路数))；单路为 0，关闭 BTB 为 0。",
                 "- 该成本为声明的逻辑寄存器位数，包括目标字段的对齐低位；综合常量消除、单元映射、面积和频率需另测。",
                 "- 每条退休指令都查询预测器。普通指令被别名表项预测跳转，也计入误预测；控制流分组包括条件分支、JAL、JALR。",
                 "- 完整命中要求方向正确，实际跳转时目标也正确。方向命中只检查 taken；错误目标会使两种命中率不同。",
                 "- MPKI = 全部退休指令上的误预测次数 / 全部退休指令数 × 1000；普通指令假跳转与控制流误预测之和等于总误预测。",
                 "- `not-taken` 只控制条件分支；命中 BTB 的 JAL 仍预测跳转。条件分支和 JAL 训练，JALR 不训练，LRU 在训练时更新。",
                 "- 回放按退休顺序即时训练。流水线训练延迟、错误路径及失效不在此统计中；零分母记为 `-`。",
                 "- 完整整数计数见 `dse.csv`；逐配置原始输出见 `dse/logs/`。", "", "## 输入记录", ""])
    for name, source in provenance.items():
        if isinstance(source, dict) and "path" in source:
            text.extend([f"- {name}: `{source['path']}`", f"  - bytes: {source['bytes']}",
                         f"  - SHA-256: `{source['sha256']}`"])
    path.write_text("\n".join(text) + "\n", encoding="utf-8")


def _values(rows: Sequence[dict], field: str) -> list[str]:
    values = {str(row[field]) for row in rows}
    return sorted(values, key=(lambda value: float(value)) if field not in ("bht", "btb_policy") else str)


def _color(field: str, value: str, values: Sequence[str]) -> str:
    if field == "bht":
        return {"btfn": "#2563eb", "not-taken": "#d97706", "bimodal": "#059669"}.get(value, "#64748b")
    return _PALETTE[list(values).index(value) % len(_PALETTE)]


def _shape(kind: str, color: str) -> str:
    style = f'fill="{color}" fill-opacity="0.8" stroke="#111827" stroke-width="0.5"'
    if kind == "circle":
        return f'<circle r="4" {style}/>'
    if kind == "square":
        return f'<rect x="-3.7" y="-3.7" width="7.4" height="7.4" {style}/>'
    if kind == "triangle":
        return f'<polygon points="0,-4.7 4.2,3.6 -4.2,3.6" {style}/>'
    if kind == "diamond":
        return f'<polygon points="0,-4.9 4.9,0 0,4.9 -4.9,0" {style}/>'
    if kind == "plus":
        return f'<path d="M-1.2,-4.5 H1.2 V-1.2 H4.5 V1.2 H1.2 V4.5 H-1.2 V1.2 H-4.5 V-1.2 H-1.2 Z" {style}/>'
    if kind == "hexagon":
        return f'<polygon points="-2.5,-4.3 2.5,-4.3 5,0 2.5,4.3 -2.5,4.3 -5,0" {style}/>'
    if kind == "cross":
        return f'<polygon points="-4,-2.2 -2.2,-4 0,-1.8 2.2,-4 4,-2.2 1.8,0 4,2.2 2.2,4 0,1.8 -2.2,4 -4,2.2 -1.8,0" {style}/>'
    if kind == "star":
        return f'<polygon points="0,-5 1.5,-1.5 4.8,-1.5 2,0.8 3,4.5 0,2.3 -3,4.5 -2,0.8 -4.8,-1.5 -1.5,-1.5" {style}/>'
    return f'<polygon points="0,4.7 4.2,-3.6 -4.2,-3.6" {style}/>'


def _ticks(lo: float, hi: float, count: int = 6) -> list[float]:
    raw = (hi - lo) / (count - 1) or 1
    mag = 10 ** math.floor(math.log10(raw))
    step = next(step * mag for step in (1, 2, 5, 10) if step * mag >= raw)
    start = math.ceil(lo / step) * step
    return [start + i * step for i in range(count + 2) if start + i * step <= hi]


def svg(rows: Sequence[dict]) -> str:
    points = [row for row in rows if row["mpki"] != "-"]
    if not points:
        return '<svg id="plot" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 600"><text x="60" y="80">No retired instructions</text></svg>'
    xmax = max(float(row["total_ff"]) for row in points) * 1.04 or 1
    ys = [float(row["mpki"]) for row in points]
    pad = (max(ys) - min(ys)) * 0.08 or max(abs(ys[0]) * 0.08, 1)
    ymin, ymax = max(0, min(ys) - pad), max(ys) + pad
    pw, ph = _W - _LEFT - _RIGHT, _H - _TOP - _BOTTOM
    def sx(value: float) -> float:
        return _LEFT + value / xmax * pw
    def sy(value: float) -> float:
        return _TOP + (ymax - value) / (ymax - ymin) * ph
    parts = [f'<svg id="plot" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {_W} {_H}" role="img" '
             'aria-label="BTB 总逻辑触发器数与 MPKI 全配置散点图">',
             '<style>text { font: 12px sans-serif; }</style>', '<rect width="100%" height="100%" fill="white"/>',
             f'<rect x="{_LEFT}" y="{_TOP}" width="{pw}" height="{ph}" fill="none" stroke="#334155"/>']
    for value in _ticks(0, xmax):
        x = sx(value)
        parts.extend([f'<path d="M{x:.2f} {_TOP} V{_TOP + ph}" stroke="#e2e8f0"/>',
                      f'<text x="{x:.2f}" y="{_TOP + ph + 20}" text-anchor="middle">{value:g}</text>'])
    for value in _ticks(ymin, ymax):
        y = sy(value)
        parts.extend([f'<path d="M{_LEFT} {y:.2f} H{_LEFT + pw}" stroke="#e2e8f0"/>',
                      f'<text x="{_LEFT - 10}" y="{y + 4:.2f}" text-anchor="end">{value:g}</text>'])
    front = pareto(points)
    coords = " ".join(f"{sx(float(row['total_ff'])):.2f},{sy(float(row['mpki'])):.2f}" for row in front)
    if coords:
        parts.append(f'<polyline id="pareto-line" points="{coords}" fill="none" stroke="#111827" '
                     'stroke-width="1.6" stroke-dasharray="6 4"/>')
    color_field = "bht" if len(_values(points, "bht")) > 1 else "target_bits"
    colors, shapes = _values(points, color_field), _values(points, "pc_bits")
    for index, row in enumerate(points):
        color = _color(color_field, str(row[color_field]), colors)
        kind = _SHAPES[shapes.index(str(row["pc_bits"])) % len(_SHAPES)]
        x, y = sx(float(row["total_ff"])), sy(float(row["mpki"]))
        title = escape(f"{label(row)}; FF={row['total_ff']}; MPKI={fmt(row['mpki'])}")
        parts.append(f'<g class="point" data-index="{index}" data-x="{x:.2f}" data-y="{y:.2f}" '
                     f'transform="translate({x:.2f} {y:.2f})"><title>{title}</title>{_shape(kind, color)}</g>')
    parts.extend([f'<text x="{_LEFT + pw / 2}" y="{_H - 16}" text-anchor="middle">Predictor flip-flops (BTB + BHT)</text>',
                  f'<text x="18" y="{_TOP + ph / 2}" text-anchor="middle" transform="rotate(-90 18 {_TOP + ph / 2})">MPKI</text>',
                  '</svg>'])
    return "\n".join(parts)


def write_plot(path: Path, rows: Sequence[dict], provenance: dict) -> None:
    data = json.dumps(rows, ensure_ascii=False).replace("<", "\\u003c")
    options = "".join(f'<button type="button" data-field="{field}">{escape(FIELD_LABELS[field])}</button>' for field in FIELDS)
    filters = "".join(f'<label>{escape(FIELD_LABELS[field])}<select data-filter="{field}"><option value="">全部</option></select></label>' for field in FIELDS)
    page = (_TEMPLATE.read_text(encoding="utf-8").replace("__ROWS__", data)
            .replace("__SVG__", svg(rows)).replace("__FIELD_BUTTONS__", options)
            .replace("__FILTERS__", filters).replace("__COUNT__", str(len(rows)))
            .replace("__BUDGET__", str(provenance.get("search", {}).get("ff_budget", FF_BUDGET))))
    path.write_text(page, encoding="utf-8")
