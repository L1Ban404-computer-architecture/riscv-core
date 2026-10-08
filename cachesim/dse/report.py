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

# 数据内嵌在页面里。file:// 打开即可，不依赖扫描进程，也不请求外部脚本。
_PAGE = """\
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title></title>
<style>
  :root { color-scheme: light; }
  body {
    margin: 0;
    background: #f8fafc;
    color: #111827;
    font: 14px/1.4 ui-sans-serif, system-ui, sans-serif;
  }
  main {
    max-width: 960px;
    margin: 0 auto;
    padding: 16px 20px 32px;
  }
  #bar { display: flex; flex-direction: column; align-items: flex-start; gap: 8px; margin: 0 0 12px; }
  .enc { display: flex; flex-wrap: wrap; align-items: center; gap: 16px; }
  .fields { display: flex; gap: 4px; }
  .fields button {
    border: 1px solid #e5e7eb;
    background: #fff;
    color: #111827;
    border-radius: 999px;
    padding: 2px 10px;
    font: inherit;
    cursor: pointer;
  }
  .fields button.on { background: #111827; color: #fff; border-color: #111827; }
  .legend { display: flex; flex-wrap: wrap; gap: 14px; font-size: 13px; }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  #color-legend i {
    width: 9px; height: 9px; border-radius: 50%;
    border: 1px solid #111827; display: inline-block;
  }
  #shape-legend svg { display: block; }
  .frame {
    background: #fff;
    border: 1px solid #e5e7eb;
    border-radius: 10px;
    padding: 8px;
  }
  svg { display: block; width: 100%; height: auto; }
  g.point { cursor: pointer; }
  #tip {
    position: fixed;
    z-index: 2;
    display: none;
    max-width: 280px;
    padding: 8px 10px;
    border-radius: 8px;
    background: #111827;
    color: #f9fafb;
    font-size: 12px;
    line-height: 1.45;
    pointer-events: none;
    box-shadow: 0 8px 24px rgba(17, 24, 39, 0.18);
  }
  #tip b { font-weight: 650; }
  #tip .muted { color: #d1d5db; }
</style>
</head>
<body>
<main>
  <div id="bar">
    <div class="enc">
      <div class="fields" id="color-fields">
        <button type="button" data-field="sets">sets</button>
        <button type="button" data-field="ways">ways</button>
        <button type="button" data-field="block_bytes">block_bytes</button>
        <button type="button" data-field="bytes">bytes</button>
        <button type="button" data-field="policy" class="on">policy</button>
      </div>
      <div class="legend" id="color-legend">__COLOR_LEGEND__</div>
    </div>
    <div class="enc">
      <div class="fields" id="shape-fields">
        <button type="button" data-field="sets" class="on">sets</button>
        <button type="button" data-field="ways">ways</button>
        <button type="button" data-field="block_bytes">block_bytes</button>
        <button type="button" data-field="bytes">bytes</button>
        <button type="button" data-field="policy">policy</button>
      </div>
      <div class="legend" id="shape-legend">__SHAPE_LEGEND__</div>
    </div>
  </div>
  <div class="frame">__SVG__</div>
</main>
<div id="tip"></div>
<script id="dse-rows" type="application/json">__ROWS__</script>
<script>
const rows = JSON.parse(document.getElementById("dse-rows").textContent);
const fields = ["sets", "ways", "block_bytes", "bytes", "policy"];
const policyColors = { rr: "#2563eb", plru: "#d97706", fixed: "#059669" };
const palette = ["#2563eb", "#d97706", "#059669", "#dc2626", "#7c3aed", "#0891b2", "#db2777", "#4f46e5"];
const shapes = ["circle", "square", "triangle", "diamond", "plus", "down"];
const NS = "http://www.w3.org/2000/svg";
let colorField = "policy";
let shapeField = "sets";
const svg = document.getElementById("plot");
const tip = document.getElementById("tip");
const width = 800, height = 560;
const nodes = [...svg.querySelectorAll("g.point")];
const points = rows.map((row, index) => ({
  row,
  node: nodes[index],
  cx: Number(nodes[index].getAttribute("data-x")),
  cy: Number(nodes[index].getAttribute("data-y")),
}));

function fmtNum(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return String(value);
  if (Number.isInteger(number)) return String(number);
  if (Math.abs(number) >= 100) return number.toFixed(2);
  return String(Number(number.toPrecision(6)));
}

function valuesOf(field) {
  const values = [...new Set(points.map((point) => String(point.row[field])))];
  if (field === "policy") {
    const order = ["fixed", "rr", "plru"];
    values.sort((a, b) => {
      const ia = order.indexOf(a);
      const ib = order.indexOf(b);
      return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || a.localeCompare(b);
    });
  } else {
    values.sort((a, b) => Number(a) - Number(b));
  }
  return values;
}

function colorOf(field, value) {
  const text = String(value);
  if (field === "policy" && policyColors[text]) return policyColors[text];
  return palette[valuesOf(field).indexOf(text) % palette.length];
}

function shapeOf(field, value) {
  return shapes[valuesOf(field).indexOf(String(value)) % shapes.length];
}

function shapeNode(kind, fill) {
  let node;
  const common = () => {
    node.setAttribute("fill", fill);
    node.setAttribute("fill-opacity", "0.85");
    node.setAttribute("stroke", "#111827");
    node.setAttribute("stroke-width", "0.6");
  };
  if (kind === "circle") {
    node = document.createElementNS(NS, "circle");
    node.setAttribute("r", "5");
  } else if (kind === "square") {
    node = document.createElementNS(NS, "rect");
    node.setAttribute("x", "-4.2");
    node.setAttribute("y", "-4.2");
    node.setAttribute("width", "8.4");
    node.setAttribute("height", "8.4");
  } else if (kind === "triangle") {
    node = document.createElementNS(NS, "polygon");
    node.setAttribute("points", "0,-5.2 4.6,4 -4.6,4");
  } else if (kind === "diamond") {
    node = document.createElementNS(NS, "polygon");
    node.setAttribute("points", "0,-5.4 5.4,0 0,5.4 -5.4,0");
  } else if (kind === "plus") {
    node = document.createElementNS(NS, "path");
    node.setAttribute("d", "M-1.4,-5 H1.4 V-1.4 H5 V1.4 H1.4 V5 H-1.4 V1.4 H-5 V-1.4 H-1.4 Z");
  } else {
    node = document.createElementNS(NS, "polygon");
    node.setAttribute("points", "0,5.2 4.6,-4 -4.6,-4");
  }
  common();
  return node;
}

function place(point, scale) {
  point.node.setAttribute("transform", `translate(${point.cx} ${point.cy}) scale(${scale})`);
}

const colorLegend = document.getElementById("color-legend");
const shapeLegend = document.getElementById("shape-legend");
const colorButtons = {};
const shapeButtons = {};
for (const button of document.querySelectorAll("#color-fields button")) {
  colorButtons[button.dataset.field] = button;
  button.addEventListener("click", () => {
    colorField = button.dataset.field;
    hideTip();
    paint();
  });
}
for (const button of document.querySelectorAll("#shape-fields button")) {
  shapeButtons[button.dataset.field] = button;
  button.addEventListener("click", () => {
    shapeField = button.dataset.field;
    hideTip();
    paint();
  });
}

function paint() {
  for (const point of points) {
    const fill = colorOf(colorField, point.row[colorField]);
    const kind = shapeOf(shapeField, point.row[shapeField]);
    point.node.replaceChildren(shapeNode(kind, fill));
    place(point, 1);
  }
  colorLegend.replaceChildren();
  for (const value of valuesOf(colorField)) {
    const item = document.createElement("span");
    const swatch = document.createElement("i");
    swatch.style.background = colorOf(colorField, value);
    item.append(swatch, document.createTextNode(value));
    colorLegend.appendChild(item);
  }
  shapeLegend.replaceChildren();
  for (const value of valuesOf(shapeField)) {
    const item = document.createElement("span");
    const icon = document.createElementNS(NS, "svg");
    icon.setAttribute("viewBox", "-7 -7 14 14");
    icon.setAttribute("width", "12");
    icon.setAttribute("height", "12");
    icon.appendChild(shapeNode(shapeOf(shapeField, value), "#111827"));
    item.append(icon, document.createTextNode(value));
    shapeLegend.appendChild(item);
  }
  for (const field of fields) {
    colorButtons[field].classList.toggle("on", field === colorField);
    shapeButtons[field].classList.toggle("on", field === shapeField);
  }
}

paint();

function tipLine(name, value) {
  const line = document.createElement("div");
  const label = document.createElement("span");
  label.className = "muted";
  label.textContent = name + " ";
  line.append(label, document.createTextNode(value));
  return line;
}

function showTip(hits, event) {
  tip.replaceChildren();
  hits.forEach((point, index) => {
    if (index) {
      const rule = document.createElement("div");
      rule.style.margin = "6px 0";
      rule.style.borderTop = "1px solid #374151";
      tip.appendChild(rule);
    }
    const row = point.row;
    const title = document.createElement("div");
    const strong = document.createElement("b");
    strong.textContent = row.sets + " 组 · " + row.ways + " 路 · " + row.block_bytes + " B · " + row.policy;
    title.appendChild(strong);
    tip.append(
      title,
      tipLine("容量", fmtNum(row.bytes) + " B"),
      tipLine("面积", fmtNum(row.synth_area)),
      tipLine("频率", fmtNum(row.synth_freq_mhz) + " MHz"),
      tipLine("命中率", String(row.hit_rate)),
      tipLine("AMT", fmtNum(row.amt)),
    );
  });
  tip.style.display = "block";
  const pad = 14;
  let x = event.clientX + pad;
  let y = event.clientY + pad;
  const box = tip.getBoundingClientRect();
  if (x + box.width > window.innerWidth - 8) x = event.clientX - box.width - pad;
  if (y + box.height > window.innerHeight - 8) y = event.clientY - box.height - pad;
  tip.style.left = Math.max(8, x) + "px";
  tip.style.top = Math.max(8, y) + "px";
  const chosen = new Set(hits);
  for (const other of points) place(other, chosen.has(other) ? 1.35 : 1);
}

function hideTip() {
  tip.style.display = "none";
  for (const point of points) place(point, 1);
}

svg.addEventListener("mousemove", (event) => {
  const rect = svg.getBoundingClientRect();
  const x = (event.clientX - rect.left) / rect.width * width;
  const y = (event.clientY - rect.top) / rect.height * height;
  const hits = points.filter((point) => Math.hypot(point.cx - x, point.cy - y) < 14);
  if (hits.length) showTip(hits, event);
  else hideTip();
});
svg.addEventListener("mouseleave", hideTip);
</script>
</body>
</html>
"""


def write_csv(path: Path, rows: Iterable[Dict[str, object]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(CSV_FIELDS))
        writer.writeheader()
        writer.writerows(rows)


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
        _PAGE.replace("__ROWS__", _embed(points))
        .replace("__SVG__", _svg(points))
        .replace("__COLOR_LEGEND__", _color_legend(points, _COLOR_FIELD))
        .replace("__SHAPE_LEGEND__", _shape_legend(points, _SHAPE_FIELD))
    )
    path.write_text(page, encoding="utf-8")
