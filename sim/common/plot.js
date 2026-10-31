"use strict";
const {plot: settings, fields, rows} = JSON.parse(document.getElementById("scan-data").textContent);
const labels = settings.labels || {};
const nameOf = field => labels[field] || field;
const byId = id => document.getElementById(id);
const numericFields = fields.filter(field => (field === settings.x || field === settings.y || rows.some(row => typeof row[field] === "number")));
const parameterFields = settings.filters || [];
const palette = ["#2563eb", "#d97706", "#059669", "#dc2626", "#7c3aed", "#0891b2", "#db2777", "#65a30d"];
const shapes = ["circle", "square", "triangle", "diamond", "cross"];
const NS = "http://www.w3.org/2000/svg";
const W = 960, H = 560, L = 86, R = 28, T = 25, B = 65;
const svg = byId("plot"), tip = byId("tip");
const selectors = Object.fromEntries(["x", "y", "color", "shape"].map(key => [key, byId(key + "-field")]));
const filters = {};
let visible = [], points = [], sortField = settings.y, ascending = true;

function element(tag, attributes = {}, text) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
  if (text !== undefined) node.textContent = text;
  return node;
}

function svgNode(tag, attributes = {}, text) {
  const node = document.createElementNS(NS, tag);
  for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
  if (text !== undefined) node.textContent = text;
  return node;
}

function compare(a, b) {
  if (a == null || b == null) return a === b ? 0 : a == null ? 1 : -1;
  return typeof a === "number" && typeof b === "number" ? a - b : String(a).localeCompare(String(b));
}

// 原始数据固定，编码和图例共用字段值，避免每个散点都重复去重、排序。
const fieldValues = new Map(fields.map(field => [field, [...new Set(rows.map(row => row[field]))].sort(compare)]));
function valuesOf(field) {
  return fieldValues.get(field);
}

function format(value) {
  if (value == null) return "—";
  return typeof value === "number" && !Number.isInteger(value) ? Number(value.toPrecision(6)).toString() : String(value);
}

function fillOptions(select, options, labeled = false) {
  for (const value of options) select.appendChild(element("option", {value}, labeled ? nameOf(value) : format(value)));
}

byId("title").textContent = document.title = settings.title;
for (const [key, select] of Object.entries(selectors)) {
  fillOptions(select, key === "x" || key === "y" ? numericFields : fields, true);
  select.value = settings[key];
  select.addEventListener("change", paint);
}
for (const field of parameterFields) {
  const select = element("select", {"data-filter": field, "aria-label": nameOf(field)});
  select.appendChild(element("option", {value: ""}, "全部"));
  fillOptions(select, valuesOf(field));
  select.addEventListener("change", paint);
  filters[field] = select;
  const label = element("label", {}, nameOf(field));
  label.appendChild(select);
  byId("filters").appendChild(label);
}
const heading = element("tr");
for (const field of fields) {
  const cell = element("th", {scope: "col", "data-field": field}, nameOf(field));
  cell.addEventListener("click", () => {
    ascending = sortField === field ? !ascending : true;
    sortField = field;
    paint();
  });
  heading.appendChild(cell);
}
byId("columns").appendChild(heading);

function frontier(source) {
  const x = selectors.x.value, y = selectors.y.value;
  const xSign = byId("x-goal").value === "min" ? 1 : -1;
  const ySign = byId("y-goal").value === "min" ? 1 : -1;
  const ordered = source.filter(row => Number.isFinite(row[x]) && Number.isFinite(row[y])).slice();
  ordered.sort((a, b) => xSign * (a[x] - b[x]) || ySign * (a[y] - b[y]));
  const result = [];
  let best = Infinity;
  for (const row of ordered) {
    if (ySign * row[y] < best) {
      result.push(row);
      best = ySign * row[y];
    }
  }
  return result;
}

function shapeNode(kind, fill) {
  const style = {fill, "fill-opacity": 0.8, stroke: "#172033", "stroke-width": 0.6};
  if (kind === "circle") return svgNode("circle", {...style, r: 4.5});
  if (kind === "square") return svgNode("rect", {...style, x: -4, y: -4, width: 8, height: 8});
  if (kind === "triangle") return svgNode("polygon", {...style, points: "0,-5 4.5,4 -4.5,4"});
  if (kind === "diamond") return svgNode("polygon", {...style, points: "0,-5 5,0 0,5 -5,0"});
  return svgNode("path", {...style, d: "M-1.5,-5 H1.5 V-1.5 H5 V1.5 H1.5 V5 H-1.5 V1.5 H-5 V-1.5 H-1.5 Z"});
}

function colorOf(row) {
  const field = selectors.color.value;
  return palette[valuesOf(field).indexOf(row[field]) % palette.length];
}

function shapeOf(row) {
  const field = selectors.shape.value;
  return shapes[valuesOf(field).indexOf(row[field]) % shapes.length];
}

function ticks(lo, hi) {
  const raw = (hi - lo) / 5;
  const magnitude = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 5, 10].find(value => value * magnitude >= raw) * magnitude;
  const result = [];
  for (let value = Math.ceil(lo / step) * step; value <= hi; value += step) result.push(value);
  return result;
}

function extent(values) {
  const lo = Math.min(...values), hi = Math.max(...values);
  const pad = (hi - lo) * 0.08 || Math.max(Math.abs(lo) * 0.08, 1);
  return [lo - pad, hi + pad];
}

function drawPlot(front) {
  svg.replaceChildren();
  points = [];
  const x = selectors.x.value, y = selectors.y.value;
  const source = visible.filter(row => Number.isFinite(row[x]) && Number.isFinite(row[y]));
  byId("empty").hidden = source.length !== 0;
  if (!source.length) return;
  const [xmin, xmax] = extent(source.map(row => row[x]));
  const [ymin, ymax] = extent(source.map(row => row[y]));
  const sx = value => L + (value - xmin) / (xmax - xmin) * (W - L - R);
  const sy = value => T + (ymax - value) / (ymax - ymin) * (H - T - B);
  svg.appendChild(svgNode("rect", {x: L, y: T, width: W - L - R, height: H - T - B, fill: "white", stroke: "#64748b"}));
  for (const value of ticks(xmin, xmax)) {
    const px = sx(value);
    svg.append(svgNode("path", {d: `M${px} ${T} V${H - B}`, stroke: "#e2e8f0"}),
      svgNode("text", {x: px, y: H - B + 22, "text-anchor": "middle"}, format(value)));
  }
  for (const value of ticks(ymin, ymax)) {
    const py = sy(value);
    svg.append(svgNode("path", {d: `M${L} ${py} H${W - R}`, stroke: "#e2e8f0"}),
      svgNode("text", {x: L - 10, y: py + 4, "text-anchor": "end"}, format(value)));
  }
  svg.append(svgNode("text", {x: (W + L - R) / 2, y: H - 15, "text-anchor": "middle"}, nameOf(x)),
    svgNode("text", {x: 20, y: (H + T - B) / 2, "text-anchor": "middle",
      transform: `rotate(-90 20 ${(H + T - B) / 2})`}, nameOf(y)));
  svg.appendChild(svgNode("polyline", {points: front.map(row => `${sx(row[x])},${sy(row[y])}`).join(" "),
    fill: "none", stroke: "#334155", "stroke-width": 1.5, "stroke-dasharray": "5 4"}));
  for (const row of source) {
    const cx = sx(row[x]), cy = sy(row[y]);
    const node = svgNode("g", {class: "point", transform: `translate(${cx} ${cy})`});
    node.appendChild(shapeNode(shapeOf(row), colorOf(row)));
    svg.appendChild(node);
    points.push({row, cx, cy});
  }
}

function drawLegend() {
  const legend = byId("legend");
  legend.replaceChildren();
  for (const kind of ["color", "shape"]) {
    const field = selectors[kind].value;
    for (const value of valuesOf(field)) {
      const row = {[field]: value};
      const icon = svgNode("svg", {viewBox: "-6 -6 12 12", "aria-hidden": "true"});
      icon.appendChild(shapeNode(kind === "shape" ? shapeOf(row) : "circle", kind === "color" ? colorOf(row) : "#64748b"));
      const item = element("span");
      item.append(icon, document.createTextNode(`${nameOf(field)}=${format(value)}`));
      legend.appendChild(item);
    }
  }
}

function paint() {
  tip.style.display = "none";
  visible = rows.filter(row => Object.entries(filters).every(([field, select]) =>
    select.value === "" || String(row[field]) === select.value));
  const front = frontier(visible);
  const x = selectors.x.value, y = selectors.y.value;
  const coordinates = new Set(front.map(row => JSON.stringify([row[x], row[y]])));
  if (byId("only-front").checked) visible = visible.filter(row => coordinates.has(JSON.stringify([row[x], row[y]])));
  visible.sort((a, b) => (ascending ? 1 : -1) * compare(a[sortField], b[sortField]));
  drawPlot(front);
  drawLegend();
  const body = byId("results");
  body.replaceChildren();
  for (const row of visible) {
    const line = element("tr");
    line.classList.toggle("front", coordinates.has(JSON.stringify([row[x], row[y]])));
    for (const field of fields) line.appendChild(element("td", {}, format(row[field])));
    body.appendChild(line);
  }
  byId("count").textContent = `${visible.length} / ${rows.length} 个配置`;
}

for (const id of ["x-goal", "y-goal", "only-front"]) byId(id).addEventListener("change", paint);
byId("reset").addEventListener("click", () => {
  for (const select of Object.values(filters)) select.value = "";
  for (const [key, select] of Object.entries(selectors)) select.value = settings[key];
  byId("x-goal").value = byId("y-goal").value = "min";
  byId("only-front").checked = false;
  sortField = settings.y;
  ascending = true;
  paint();
});
byId("download").addEventListener("click", () => {
  const quote = value => '"' + String(value ?? "").replaceAll('"', '""') + '"';
  const csv = [fields, ...visible.map(row => fields.map(field => row[field]))]
    .map(line => line.map(quote).join(",")).join("\n");
  const url = URL.createObjectURL(new Blob([csv], {type: "text/csv;charset=utf-8"}));
  const link = element("a", {href: url, download: "selection.csv"});
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});
svg.addEventListener("mousemove", event => {
  const rect = svg.getBoundingClientRect();
  const x = (event.clientX - rect.left) / rect.width * W;
  const y = (event.clientY - rect.top) / rect.height * H;
  const hits = points.filter(point => Math.hypot(point.cx - x, point.cy - y) < 12);
  tip.replaceChildren();
  tip.style.display = hits.length ? "block" : "none";
  const detailFields = [...new Set(["id", ...parameterFields, selectors.x.value, selectors.y.value])];
  for (const [index, point] of hits.slice(0, 3).entries()) {
    if (index) tip.appendChild(element("hr"));
    for (const field of detailFields) tip.appendChild(element("div", {}, `${nameOf(field)}: ${format(point.row[field])}`));
  }
  if (hits.length > 3) tip.appendChild(element("div", {}, `共 ${hits.length} 个重合配置，完整数据见表格。`));
  const box = tip.getBoundingClientRect();
  tip.style.left = Math.max(8, Math.min(event.clientX + 14, window.innerWidth - box.width - 8)) + "px";
  tip.style.top = Math.max(8, Math.min(event.clientY + 14, window.innerHeight - box.height - 8)) + "px";
});
svg.addEventListener("mouseleave", () => { tip.style.display = "none"; });
paint();
