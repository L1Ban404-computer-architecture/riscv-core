#!/usr/bin/env python3
# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

"""Sweep icache geometry: hit rate, AMT estimate, and 1GHz STA PPA."""

from __future__ import annotations

import argparse
import csv
import math
import os
import re
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple
from xml.sax.saxutils import escape as xml_escape

RESULT_RE = re.compile(
    r"accesses=(?P<accesses>\d+)\s+"
    r"hits=(?P<hits>\d+)\s+"
    r"misses=(?P<misses>\d+)\s+"
    r"hit_rate=(?P<hit_rate>\S+)"
)
AREA_RE = re.compile(
    r"Chip area for module '\\icache_dse':\s*(?P<area>[0-9.]+)"
)

CORE_DIR = Path(__file__).resolve().parents[2]
DEFAULT_CACHESIM = CORE_DIR / "build" / "cachesim" / "cachesim"
DEFAULT_WORK_ROOT = CORE_DIR / "build" / "cachesim" / "dse"
DEFAULT_OUTPUT = CORE_DIR / "build" / "cachesim" / "dse.csv"
DEFAULT_PLOT = CORE_DIR / "build" / "cachesim" / "dse.svg"
DEFAULT_YOSYS_STA_HOME = Path(
    os.environ.get("YOSYS_STA_HOME", str(Path.home() / ".local" / "yosys-sta"))
)
YOSYS = os.environ.get("YOSYS", "yosys")
PDK = os.environ.get("PDK", "nangate45")

BEAT_LAT = 68.0  # 4B 块的固定 miss lat
CLK_FREQ_MHZ = 1000
DESIGN = "icache_dse"
CLK_PORT_NAME = "clk_i"

# 阵列按触发器综合。64 组 / 4 路 / 32B 会到数十万面积，而芯片总预算约
# 25000（nangate45），还要留给五级流水核心，所以默认只扫超小几何（约 16B–256B）。
DEFAULT_SETS = (4, 8, 16)
DEFAULT_WAYS = (1, 2)
DEFAULT_BLOCKS = (4, 8)
DEFAULT_POLICIES = ("rr", "plru")

POLICY_ENUM = {
    "fixed": "ICACHE_REPLACEMENT_FIXED",
    "rr": "ICACHE_REPLACEMENT_ROUND_ROBIN",
    "plru": "ICACHE_REPLACEMENT_TREE_PLRU",
}
POLICY_COLORS = {
    "rr": "#2563eb",
    "plru": "#d97706",
    "fixed": "#059669",
}
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

ICACHE_RTL = (
    "rtl/bus/riscv_bus_pkg.sv",
    "rtl/icache/icache_pkg.sv",
    "rtl/bus/riscv_bus_if.sv",
    "rtl/icache/icache_if.sv",
    "rtl/common/sram_1rw.sv",
    "rtl/icache/icache_replacement_policy.sv",
    "rtl/icache/icache_array.sv",
    "rtl/icache/icache_control.sv",
    "rtl/icache/icache.sv",
    "rtl/top/icache_top.sv",
)

Job = Tuple[str, str, int, int, int, str, str, str, str, str]


def miss_penalty(block_bytes: int, beat_lat: float = BEAT_LAT) -> float:
    return beat_lat * (block_bytes / 4)


def amt(hit_rate: float, penalty: float) -> float:
    return (1.0 - hit_rate) * penalty


def parse_u32_list(text: str) -> Tuple[int, ...]:
    values = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        values.append(int(part, 0))
    if not values:
        raise argparse.ArgumentTypeError("expected at least one integer")
    return tuple(values)


def parse_cachesim_output(text: str) -> Dict[str, str]:
    match = RESULT_RE.search(text)
    if match is None:
        raise RuntimeError(f"unrecognized cachesim output: {text!r}")
    return match.groupdict()


def parse_hit_rate(text: str) -> Optional[float]:
    if text == "-":
        return None
    return float(text)


def geom_name(sets: int, ways: int, block_bytes: int, policy: str) -> str:
    return f"s{sets}_w{ways}_b{block_bytes}_{policy}"


def sta_result_dir(work: Path) -> Path:
    return work / "sta" / f"{DESIGN}-{CLK_FREQ_MHZ}MHz"


def synth_stat_path(work: Path) -> Path:
    return sta_result_dir(work) / "synth_stat.txt"


def sta_report_path(work: Path) -> Path:
    return sta_result_dir(work) / f"{DESIGN}.rpt"


def parse_synth_area(text: str) -> float:
    match = AREA_RE.search(text)
    if match is None:
        raise RuntimeError("missing Chip area for module '\\icache_dse' in synth_stat.txt")
    return float(match.group("area"))


def parse_synth_freq_mhz(text: str) -> float:
    in_table = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if len(cells) < 8:
            continue
        if cells[0] == "Endpoint" and cells[1] == "Clock Group":
            in_table = True
            continue
        if not in_table:
            continue
        if cells[1] == "core_clock" and cells[2] == "max":
            try:
                return float(cells[7])
            except ValueError as exc:
                raise RuntimeError(
                    f"invalid Freq(MHz) in STA report: {cells[7]!r}"
                ) from exc
    raise RuntimeError("no core_clock max Freq(MHz) in STA report")


def try_parse_existing_sta(work: Path) -> Optional[Tuple[float, float]]:
    stat = synth_stat_path(work)
    rpt = sta_report_path(work)
    if not stat.is_file() or not rpt.is_file():
        return None
    try:
        area = parse_synth_area(stat.read_text(encoding="utf-8", errors="replace"))
        freq = parse_synth_freq_mhz(rpt.read_text(encoding="utf-8", errors="replace"))
    except RuntimeError:
        return None
    return freq, area


def wrapper_sv(sets: int, ways: int, block_bytes: int, policy: str) -> str:
    enum_name = POLICY_ENUM[policy]
    return f"""// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Generated DSE wrapper. Do not edit.

module icache_dse
  import riscv_bus_pkg::*;
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = ICACHE_AXI_ID,
  parameter int unsigned BlockBytes = ICacheBlockBytes,
  parameter int unsigned SetCount = ICacheSetCount,
  parameter int unsigned WayCount = ICacheWayCount,
  parameter icache_replacement_policy_e ReplacementPolicy = ICacheReplacementPolicy,
  localparam int unsigned StrbWidth = DataWidth / 8
) (
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,

  input logic req_valid_i,
  output logic req_ready_o,
  input logic [AddrWidth-1:0] req_addr_i,
  input logic req_write_i,
  input logic [1:0] req_size_i,
  input logic [DataWidth-1:0] req_wdata_i,
  input logic [StrbWidth-1:0] req_wstrb_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output logic [DataWidth-1:0] rsp_rdata_o,
  output logic rsp_error_o,

  input logic axi_awready_i,
  output logic axi_awvalid_o,
  output logic [AddrWidth-1:0] axi_awaddr_o,
  output logic [IdWidth-1:0] axi_awid_o,
  output logic [7:0] axi_awlen_o,
  output logic [2:0] axi_awsize_o,
  output logic [1:0] axi_awburst_o,
  input logic axi_wready_i,
  output logic axi_wvalid_o,
  output logic [DataWidth-1:0] axi_wdata_o,
  output logic [StrbWidth-1:0] axi_wstrb_o,
  output logic axi_wlast_o,
  output logic axi_bready_o,
  input logic axi_bvalid_i,
  input logic [1:0] axi_bresp_i,
  input logic [IdWidth-1:0] axi_bid_i,
  input logic axi_arready_i,
  output logic axi_arvalid_o,
  output logic [AddrWidth-1:0] axi_araddr_o,
  output logic [IdWidth-1:0] axi_arid_o,
  output logic [7:0] axi_arlen_o,
  output logic [2:0] axi_arsize_o,
  output logic [1:0] axi_arburst_o,
  output logic axi_rready_o,
  input logic axi_rvalid_i,
  input logic [1:0] axi_rresp_i,
  input logic [DataWidth-1:0] axi_rdata_i,
  input logic axi_rlast_i,
  input logic [IdWidth-1:0] axi_rid_i
);

  icache_top #(
    .BlockBytes({block_bytes}),
    .SetCount({sets}),
    .WayCount({ways}),
    .ReplacementPolicy(icache_pkg::{enum_name})
  ) u_icache (.*);

endmodule
"""


def write_filelist(path: Path, wrapper: Path) -> None:
    lines = [
        "-Irtl",
        f"--top {DESIGN}",
        *ICACHE_RTL,
        wrapper.resolve().as_posix(),
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def run_logged(command: Sequence[str], log_path: Path, cwd: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
        log.write("+ " + " ".join(command) + "\n")
        log.flush()
        completed = subprocess.run(
            list(command),
            cwd=cwd,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
            text=True,
        )
    if completed.returncode != 0:
        tail = log_path.read_text(encoding="utf-8", errors="replace")[-4000:]
        raise RuntimeError(
            f"{' '.join(command)} failed (log {log_path}):\n{tail}"
        )


def synthesize_geometry(
    core_dir: Path,
    work: Path,
    sets: int,
    ways: int,
    block_bytes: int,
    policy: str,
    yosys: str,
    yosys_sta_home: Path,
) -> Tuple[float, float]:
    existing = try_parse_existing_sta(work)
    wrapper = work / "icache_dse.sv"
    work.mkdir(parents=True, exist_ok=True)
    wrapper.write_text(
        wrapper_sv(sets, ways, block_bytes, policy), encoding="utf-8"
    )
    if existing is not None:
        return existing

    filelist = work / "icache_dse.f"
    rtl_v = work / "rtl.v"
    write_filelist(filelist, wrapper)

    slang_cmd = [
        yosys,
        "-Q",
        "-T",
        "-p",
        "plugin -i slang; read_slang -D SYNTHESIS --single-unit "
        f"--ignore-assertions -f {filelist.resolve().as_posix()}; "
        f"proc; bwmuxmap; write_verilog {rtl_v.resolve().as_posix()}",
    ]
    run_logged(slang_cmd, work / "slang.log", core_dir)

    sta_out = work / "sta"
    sta_cmd = [
        "make",
        "-B",
        "-C",
        str(yosys_sta_home),
        "sta",
        f"DESIGN={DESIGN}",
        f"CLK_PORT_NAME={CLK_PORT_NAME}",
        f"CLK_FREQ_MHZ={CLK_FREQ_MHZ}",
        f"PDK={PDK}",
        f"RTL_FILES={rtl_v.resolve().as_posix()}",
        f"O={sta_out.resolve().as_posix()}",
    ]
    run_logged(sta_cmd, work / "sta_make.log", core_dir)

    parsed = try_parse_existing_sta(work)
    if parsed is None:
        raise RuntimeError(f"STA reports missing or unreadable under {sta_out}")
    return parsed


def run_cachesim(
    cachesim: str, trace: str, sets: int, ways: int, block_bytes: int, policy: str
) -> Dict[str, str]:
    command = [
        cachesim,
        "--trace",
        trace,
        "--sets",
        str(sets),
        "--ways",
        str(ways),
        "--block-bytes",
        str(block_bytes),
        "--policy",
        policy,
    ]
    completed = subprocess.run(
        command, check=False, capture_output=True, text=True
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"{' '.join(command)} failed:\n{completed.stderr or completed.stdout}"
        )
    return parse_cachesim_output(completed.stdout)


def run_one(args: Job) -> Dict[str, object]:
    (
        cachesim,
        trace,
        sets,
        ways,
        block_bytes,
        policy,
        core_dir,
        work_root,
        yosys,
        yosys_sta_home,
    ) = args
    work = Path(work_root) / PDK / geom_name(sets, ways, block_bytes, policy)
    freq, area = synthesize_geometry(
        Path(core_dir),
        work,
        sets,
        ways,
        block_bytes,
        policy,
        yosys,
        Path(yosys_sta_home),
    )
    parsed = run_cachesim(cachesim, trace, sets, ways, block_bytes, policy)
    penalty = miss_penalty(block_bytes)
    hit = parse_hit_rate(parsed["hit_rate"])
    estimated_amt = "-" if hit is None else amt(hit, penalty)
    return {
        "sets": sets,
        "ways": ways,
        "block_bytes": block_bytes,
        "policy": policy,
        "synth_area": area,
        "synth_freq_mhz": freq,
        "hit_rate": parsed["hit_rate"],
        "amt": estimated_amt,
    }


def expand_jobs(
    cachesim: str,
    trace: str,
    sets: Sequence[int],
    ways: Sequence[int],
    blocks: Sequence[int],
    policies: Sequence[str],
    core_dir: str,
    work_root: str,
    yosys: str,
    yosys_sta_home: str,
) -> List[Job]:
    jobs: List[Job] = []
    for set_count, way_count, block_bytes, policy in (
        (s, w, b, p)
        for s in sets
        for w in ways
        for b in blocks
        for p in policies
    ):
        jobs.append(
            (
                cachesim,
                trace,
                set_count,
                way_count,
                block_bytes,
                policy,
                core_dir,
                work_root,
                yosys,
                yosys_sta_home,
            )
        )
    return jobs


def write_csv(path: Optional[str], rows: Iterable[Dict[str, object]]) -> None:
    handle = open(path, "w", encoding="utf-8", newline="") if path else sys.stdout
    close = path is not None
    try:
        writer = csv.DictWriter(handle, fieldnames=list(CSV_FIELDS), extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
    finally:
        if close:
            handle.close()


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
    value = start
    while value <= hi + nice * 0.01:
        ticks.append(value)
        value += nice
    return ticks


def _fmt_tick(value: float) -> str:
    if abs(value) >= 1000:
        return f"{value:.0f}"
    text = f"{value:.4g}"
    return text


def write_scatter(path: Path, rows: Sequence[Dict[str, object]]) -> None:
    points = []
    for row in rows:
        if str(row["amt"]) == "-":
            continue
        points.append(
            (
                float(row["synth_area"]),
                float(row["amt"]),
                str(row["policy"]),
                geom_name(
                    int(row["sets"]),
                    int(row["ways"]),
                    int(row["block_bytes"]),
                    str(row["policy"]),
                ),
            )
        )
    if not points:
        raise RuntimeError("no points with AMT to plot")

    width, height = 800, 560
    left, right, top, bottom = 72, 28, 28, 64
    plot_w = width - left - right
    plot_h = height - top - bottom
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    x_min, x_max = min(xs), max(xs)
    y_min, y_max = min(ys), max(ys)
    x_pad = (x_max - x_min) * 0.08 or max(abs(x_max) * 0.08, 1.0)
    y_pad = (y_max - y_min) * 0.08 or max(abs(y_max) * 0.08, 1.0)
    x_min -= x_pad
    x_max += x_pad
    y_min -= y_pad
    y_max += y_pad

    def sx(area: float) -> float:
        return left + (area - x_min) / (x_max - x_min) * plot_w

    def sy(amt_value: float) -> float:
        return top + (1.0 - (amt_value - y_min) / (y_max - y_min)) * plot_h

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        f'<rect x="{left}" y="{top}" width="{plot_w}" height="{plot_h}" '
        'fill="none" stroke="#111827" stroke-width="1"/>',
    ]
    for tick in _nice_ticks(x_min, x_max):
        if tick < x_min or tick > x_max:
            continue
        x = sx(tick)
        parts.append(
            f'<line x1="{x:.2f}" y1="{top}" x2="{x:.2f}" y2="{top + plot_h}" '
            'stroke="#e5e7eb" stroke-width="1"/>'
        )
        parts.append(
            f'<text x="{x:.2f}" y="{top + plot_h + 18}" text-anchor="middle" '
            f'font-size="12" fill="#111827">{_fmt_tick(tick)}</text>'
        )
    for tick in _nice_ticks(y_min, y_max):
        if tick < y_min or tick > y_max:
            continue
        y = sy(tick)
        parts.append(
            f'<line x1="{left}" y1="{y:.2f}" x2="{left + plot_w}" y2="{y:.2f}" '
            'stroke="#e5e7eb" stroke-width="1"/>'
        )
        parts.append(
            f'<text x="{left - 8}" y="{y:.2f}" text-anchor="end" '
            f'dominant-baseline="middle" font-size="12" fill="#111827">'
            f"{_fmt_tick(tick)}</text>"
        )
    parts.append(
        f'<text x="{left + plot_w / 2:.2f}" y="{height - 16}" text-anchor="middle" '
        'font-size="14" fill="#111827">面积</text>'
    )
    parts.append(
        f'<text x="18" y="{top + plot_h / 2:.2f}" text-anchor="middle" '
        f'transform="rotate(-90 18 {top + plot_h / 2:.2f})" '
        'font-size="14" fill="#111827">AMT</text>'
    )
    used_policies = []
    for area, amt_value, policy, name in points:
        color = POLICY_COLORS.get(policy, "#111827")
        if policy not in used_policies:
            used_policies.append(policy)
        parts.append(
            f'<circle cx="{sx(area):.2f}" cy="{sy(amt_value):.2f}" r="4.5" '
            f'fill="{color}" fill-opacity="0.85" stroke="#111827" stroke-width="0.6">'
            f"<title>{xml_escape(name)}</title></circle>"
        )
    legend_x = left + plot_w - 90
    legend_y = top + 16
    for index, policy in enumerate(used_policies):
        y = legend_y + index * 18
        color = POLICY_COLORS.get(policy, "#111827")
        parts.append(
            f'<circle cx="{legend_x}" cy="{y}" r="4.5" fill="{color}" '
            'stroke="#111827" stroke-width="0.6"/>'
        )
        parts.append(
            f'<text x="{legend_x + 10}" y="{y}" dominant-baseline="middle" '
            f'font-size="12" fill="#111827">{xml_escape(policy)}</text>'
        )
    parts.append("</svg>")
    path.write_text("\n".join(parts) + "\n", encoding="utf-8")


def amt_key(row: Dict[str, object]) -> float:
    text = str(row["amt"])
    if text == "-":
        return float("inf")
    return float(text)


def area_key(row: Dict[str, object]) -> float:
    return float(row["synth_area"])


def require_yosys_sta(home: Path) -> None:
    makefile = home / "Makefile"
    ieda = home / "bin" / "iEDA"
    pdk = home / "pdk" / PDK
    if not makefile.is_file() or not os.access(ieda, os.X_OK):
        raise SystemExit(
            f"请先安装 yosys-sta，并设置 YOSYS_STA_HOME（当前 {home}）。"
        )
    if not pdk.is_dir():
        raise SystemExit(
            f"缺少工艺库 {pdk}。nangate45 可从 "
            "https://ysyx.oscc.cc/slides/resources/archive/nangate45.tar.bz2 "
            "解压到 yosys-sta/pdk/。"
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Sweep common icache geometries against one PC trace, estimate AMT "
            "(beat_lat=68), run 1GHz yosys-sta, and write a CSV plus area-AMT scatter."
        )
    )
    parser.add_argument("--trace", required=True, help="binary PC trace")
    parser.add_argument(
        "--cachesim",
        default=str(DEFAULT_CACHESIM),
        help="cachesim binary",
    )
    parser.add_argument("--sets", type=parse_u32_list, default=DEFAULT_SETS)
    parser.add_argument("--ways", type=parse_u32_list, default=DEFAULT_WAYS)
    parser.add_argument(
        "--block-bytes", type=parse_u32_list, default=DEFAULT_BLOCKS
    )
    parser.add_argument(
        "--policy",
        default=",".join(DEFAULT_POLICIES),
        help="comma-separated policies: fixed,rr,plru",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=1,
        help="parallel workers, 1=serial (default), 0=CPU count",
    )
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT),
        help="CSV path; '-' writes to stdout",
    )
    parser.add_argument(
        "--plot",
        default=str(DEFAULT_PLOT),
        help="area-vs-AMT SVG path; empty string skips the plot",
    )
    ns = parser.parse_args()

    policies = tuple(part.strip() for part in ns.policy.split(",") if part.strip())
    if not policies:
        parser.error("need at least one --policy")
    unknown = [policy for policy in policies if policy not in POLICY_ENUM]
    if unknown:
        parser.error(f"unknown --policy {unknown}; expected {sorted(POLICY_ENUM)}")

    yosys_sta_home = DEFAULT_YOSYS_STA_HOME
    require_yosys_sta(yosys_sta_home)

    jobs = expand_jobs(
        ns.cachesim,
        ns.trace,
        ns.sets,
        ns.ways,
        ns.block_bytes,
        policies,
        str(CORE_DIR),
        str(DEFAULT_WORK_ROOT),
        YOSYS,
        str(yosys_sta_home),
    )
    output_path = None if ns.output == "-" else ns.output
    plot_path = Path(ns.plot) if ns.plot else None
    if output_path:
        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    print(
        f"sweep {len(jobs)} configs -> {output_path or 'stdout'}"
        + (f", {plot_path}" if plot_path else ""),
        file=sys.stderr,
    )
    workers = None if ns.jobs == 0 else ns.jobs
    rows: List[Dict[str, object]] = []
    with ProcessPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(run_one, job) for job in jobs]
        for index, future in enumerate(as_completed(futures), start=1):
            row = future.result()
            rows.append(row)
            print(
                f"[{index}/{len(jobs)}] "
                f"{geom_name(int(row['sets']), int(row['ways']), int(row['block_bytes']), str(row['policy']))}",
                file=sys.stderr,
            )

    rows.sort(
        key=lambda row: (
            amt_key(row),
            area_key(row),
            int(row["sets"]),
            int(row["ways"]),
            int(row["block_bytes"]),
            str(row["policy"]),
        )
    )
    write_csv(output_path, rows)
    if plot_path is not None:
        plot_path.parent.mkdir(parents=True, exist_ok=True)
        write_scatter(plot_path, rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
