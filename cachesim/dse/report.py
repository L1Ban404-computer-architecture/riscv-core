# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

"""把扫描结果写成 CSV，以及一份可离线打开的面积–AMT 散点页。"""

from __future__ import annotations

import csv
import json
import math
from html import escape
from pathlib import Path
from typing import Dict, Iterable, List, Sequence

CSV_FIELDS = (
    "sets",
    "ways",
    "block_bytes",
    "policy",
    "synth_area",
    "synth_freq_mhz",
    "hit_rate",
    "amt",
)

_TEMPLATE = Path(__file__).with_name("plot.html")


_PLOT_W = 800
_PLOT_H = 560
_LEFT, _RIGHT, _TOP, _BOTTOM = 72, 28, 28, 64
_POLICY_COLORS = {"rr": "#2563eb", "plru": "#d97706", "fixed": "#059669"}
_POLICY_ORDER = ("fixed", "rr", "plru")
_SHAPES = ("circle", "square", "triangle", "diamond", "plus", "down")
_COLOR_FIELD = "policy"
_SHAPE_FIELD = "sets"
_PALETTE = (
    "#2563eb",
    "#d97706",
    "#059669",
    "#dc2626",
    "#7c3aed",
    "#0891b2",
    "#db2777",
    "#4f46e5",
)


def write_csv(path: Path, rows: Iterable[Dict[str, object]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(CSV_FIELDS))
        writer.writeheader()
        writer.writerows(rows)


def _embed(value: object) -> str:
    # 防止结果里的 "<" 被当成标签，提前结束内嵌的 JSON 脚本。
    return json.dumps(value, ensure_ascii=False).replace("<", "\\u003c")


def _nice_ticks(lo: float, hi: float, count: int = 5) -> List[float]:
    if hi <= lo:
        span = 1.0 if hi == 0 else abs(hi)
        lo, hi = lo - span * 0.05, hi + span * 0.05
    raw = (hi - lo) / max(count - 1, 1)
    mag = 10 ** math.floor(math.log10(raw)) if raw > 0 else 1.0
    nice = mag
    for step in (1.0, 2.0, 5.0, 10.0):
        if step * mag >= raw:
            nice = step * mag
            break
    start = math.floor(lo / nice) * nice
    ticks: List[float] = []
    for index in range(count + 4):
        value = start + index * nice
        if value > hi + nice * 0.01:
            break
        ticks.append(value)
    return ticks


def _fmt_tick(value: float) -> str:
    if abs(value) >= 1000:
        return f"{value:.0f}"
    return format(float(f"{value:.4g}"), "g")


def _field_values(rows: Sequence[Dict[str, object]], field: str) -> List[str]:
    values = list(dict.fromkeys(str(row[field]) for row in rows))
    if field == "policy":
        values.sort(
            key=lambda item: (
                _POLICY_ORDER.index(item) if item in _POLICY_ORDER else 99,
                item,
            )
        )
    else:
        values.sort(key=float)
    return values


def _color(field: str, value: str, values: Sequence[str]) -> str:
    if field == "policy" and value in _POLICY_COLORS:
        return _POLICY_COLORS[value]
    return _PALETTE[list(values).index(value) % len(_PALETTE)]


def _shape_name(field: str, value: str, values: Sequence[str]) -> str:
    return _SHAPES[list(values).index(value) % len(_SHAPES)]


def _shape_body(kind: str, fill: str) -> str:
    style = f'fill="{fill}" fill-opacity="0.85" stroke="#111827" stroke-width="0.6"'
    if kind == "circle":
        return f"<circle r=\"5\" {style}/>"
    if kind == "square":
        return f"<rect x=\"-4.2\" y=\"-4.2\" width=\"8.4\" height=\"8.4\" {style}/>"
    if kind == "triangle":
        return f"<polygon points=\"0,-5.2 4.6,4 -4.6,4\" {style}/>"
    if kind == "diamond":
        return f"<polygon points=\"0,-5.4 5.4,0 0,5.4 -5.4,0\" {style}/>"
    if kind == "plus":
        return (
            f"<path d=\"M-1.4,-5 H1.4 V-1.4 H5 V1.4 H1.4 V5 H-1.4 V1.4 H-5 V-1.4 H-1.4 Z\" {style}/>"
        )
    return f"<polygon points=\"0,5.2 4.6,-4 -4.6,-4\" {style}/>"


def _color_legend(rows: Sequence[Dict[str, object]], field: str) -> str:
    values = _field_values(rows, field)
    return "".join(
        f'<span><i style="background:{_color(field, value, values)}"></i>{escape(value)}</span>'
        for value in values
    )


def _shape_legend(rows: Sequence[Dict[str, object]], field: str) -> str:
    values = _field_values(rows, field)
    parts = []
    for value in values:
        kind = _shape_name(field, value, values)
        icon = (
            '<svg viewBox="-7 -7 14 14" width="12" height="12" aria-hidden="true">'
            f"{_shape_body(kind, '#111827')}</svg>"
        )
        parts.append(f"<span>{icon}{escape(value)}</span>")
    return "".join(parts)


def _pareto(rows: Sequence[Dict[str, object]]) -> List[Dict[str, object]]:
    """面积和 AMT 都更小才算更优。按面积从小到大，只留下把 AMT 再压低的点。"""
    ordered = sorted(rows, key=lambda row: (float(row["synth_area"]), float(row["amt"])))
    front: List[Dict[str, object]] = []
    best_amt = float("inf")
    for row in ordered:
        amt_value = float(row["amt"])
        if amt_value < best_amt:
            front.append(row)
            best_amt = amt_value
    return front


def _svg(rows: Sequence[Dict[str, object]]) -> str:
    xs = [float(row["synth_area"]) for row in rows]
    ys = [float(row["amt"]) for row in rows]
    x_min, x_max = min(xs), max(xs)
    y_min, y_max = min(ys), max(ys)
    x_pad = (x_max - x_min) * 0.08 or max(abs(x_max) * 0.08, 1.0)
    y_pad = (y_max - y_min) * 0.08 or max(abs(y_max) * 0.08, 1.0)
    x_min -= x_pad
    x_max += x_pad
    y_min -= y_pad
    y_max += y_pad
    plot_w = _PLOT_W - _LEFT - _RIGHT
    plot_h = _PLOT_H - _TOP - _BOTTOM

    def sx(area: float) -> float:
        return _LEFT + (area - x_min) / (x_max - x_min) * plot_w

    def sy(amt_value: float) -> float:
        return _TOP + (1.0 - (amt_value - y_min) / (y_max - y_min)) * plot_h

    parts = [
        f'<svg id="plot" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {_PLOT_W} {_PLOT_H}" '
        f'width="{_PLOT_W}" height="{_PLOT_H}">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        f'<rect x="{_LEFT}" y="{_TOP}" width="{plot_w}" height="{plot_h}" '
        'fill="none" stroke="#111827"/>',
    ]
    for tick in _nice_ticks(x_min, x_max):
        if tick < x_min or tick > x_max:
            continue
        x = sx(tick)
        parts.append(
            f'<line x1="{x:.2f}" y1="{_TOP}" x2="{x:.2f}" y2="{_TOP + plot_h}" stroke="#e5e7eb"/>'
        )
        parts.append(
            f'<text x="{x:.2f}" y="{_TOP + plot_h + 18}" text-anchor="middle" '
            f'font-size="12" fill="#111827">{escape(_fmt_tick(tick))}</text>'
        )
    for tick in _nice_ticks(y_min, y_max):
        if tick < y_min or tick > y_max:
            continue
        y = sy(tick)
        parts.append(
            f'<line x1="{_LEFT}" y1="{y:.2f}" x2="{_LEFT + plot_w}" y2="{y:.2f}" stroke="#e5e7eb"/>'
        )
        parts.append(
            f'<text x="{_LEFT - 8}" y="{y:.2f}" text-anchor="end" dominant-baseline="middle" '
            f'font-size="12" fill="#111827">{escape(_fmt_tick(tick))}</text>'
        )
    parts.append(
        f'<text x="{_LEFT + plot_w / 2:.2f}" y="{_PLOT_H - 16}" text-anchor="middle" '
        'font-size="14" fill="#111827">面积</text>'
    )
    parts.append(
        f'<text x="18" y="{_TOP + plot_h / 2:.2f}" text-anchor="middle" font-size="14" '
        f'fill="#111827" transform="rotate(-90 18 {_TOP + plot_h / 2:.2f})">AMT</text>'
    )
    front = _pareto(rows)
    if len(front) >= 2:
        coords = " ".join(
            f"{sx(float(row['synth_area'])):.2f},{sy(float(row['amt'])):.2f}" for row in front
        )
        parts.append(
            f'<polyline points="{coords}" fill="none" stroke="#6b7280" stroke-width="1.2" '
            'stroke-dasharray="5 4" stroke-linejoin="round"/>'
        )
    color_values = _field_values(rows, _COLOR_FIELD)
    shape_values = _field_values(rows, _SHAPE_FIELD)
    for row in rows:
        x = sx(float(row["synth_area"]))
        y = sy(float(row["amt"]))
        color = _color(_COLOR_FIELD, str(row[_COLOR_FIELD]), color_values)
        kind = _shape_name(_SHAPE_FIELD, str(row[_SHAPE_FIELD]), shape_values)
        parts.append(
            f'<g class="point" data-x="{x:.2f}" data-y="{y:.2f}" '
            f'transform="translate({x:.2f} {y:.2f})">{_shape_body(kind, color)}</g>'
        )
    parts.append("</svg>")
    return "\n".join(parts)


def _with_bytes(rows: Sequence[Dict[str, object]]) -> List[Dict[str, object]]:
    points = []
    for row in rows:
        if str(row["amt"]) == "-":
            continue
        item = dict(row)
        item["bytes"] = int(row["sets"]) * int(row["ways"]) * int(row["block_bytes"])
        points.append(item)
    return points


def write_plot(path: Path, rows: Sequence[Dict[str, object]]) -> None:
    points = _with_bytes(rows)
    if not points:
        raise RuntimeError("no points with AMT to plot")
    page = (
        _TEMPLATE.read_text(encoding="utf-8")
        .replace("__ROWS__", _embed(points))
        .replace("__SVG__", _svg(points))
        .replace("__COLOR_LEGEND__", _color_legend(points, _COLOR_FIELD))
        .replace("__SHAPE_LEGEND__", _shape_legend(points, _SHAPE_FIELD))
    )
    path.write_text(page, encoding="utf-8")
