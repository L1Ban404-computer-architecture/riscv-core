# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

"""一次几何的综合：调用 rtl/Makefile 的 perf，读回面积和频率。"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

# 与 icache_pkg 的枚举名一致。read_slang -G 不接受整数值。
POLICY_PARAM = {
    "fixed": "ICACHE_REPLACEMENT_FIXED",
    "rr": "ICACHE_REPLACEMENT_ROUND_ROBIN",
    "plru": "ICACHE_REPLACEMENT_TREE_PLRU",
}

DESIGN = "icache_top"
CLK_FREQ_MHZ = 1000
CLK_PORT_NAME = "clk_i"
PDK = os.environ.get("PDK", "nangate45")

RTL_DIR = Path(__file__).resolve().parents[2] / "rtl"

_AREA_RE = re.compile(
    rf"Chip area for module '\\{DESIGN}':\s*(?P<area>[0-9.]+)"
)


def result_dir(work: Path) -> Path:
    return work / f"{DESIGN}-{CLK_FREQ_MHZ}MHz"


def parse_area(text: str) -> float:
    match = _AREA_RE.search(text)
    if match is None:
        raise RuntimeError(f"missing Chip area for module '\\{DESIGN}'")
    return float(match.group("area"))


def parse_freq_mhz(text: str) -> float:
    """STA 表里 core_clock / max 那一行的 Freq(MHz)。"""
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
        if in_table and cells[1] == "core_clock" and cells[2] == "max":
            return float(cells[7])
    raise RuntimeError("no core_clock max Freq(MHz) in STA report")


def saved(work: Path) -> tuple[float, float] | None:
    """报告都能解析时返回 (频率 MHz, 面积)，否则返回 None 以便重新综合。"""
    directory = result_dir(work)
    stat = directory / "synth_stat.txt"
    report = directory / f"{DESIGN}.rpt"
    if not stat.is_file() or not report.is_file():
        return None
    try:
        area = parse_area(stat.read_text(encoding="utf-8", errors="replace"))
        freq = parse_freq_mhz(report.read_text(encoding="utf-8", errors="replace"))
    except (RuntimeError, ValueError):
        return None
    return freq, area


# 失败时只保留日志结尾，避免把整次综合过程塞进异常。
_LOG_TAIL_LINES = 60


def slang_params(block_bytes: int, sets: int, ways: int, policy: str) -> str:
    return (
        f"-GBlockBytes={block_bytes} -GSetCount={sets} -GWayCount={ways} "
        f"-GReplacementPolicy={POLICY_PARAM[policy]}"
    )


def synthesize(
    work: Path, sets: int, ways: int, block_bytes: int, policy: str
) -> tuple[float, float]:
    found = saved(work)
    if found is not None:
        return found

    # 几何参数经 -G 覆盖 icache_top，源文件列表留在 rtl/Makefile。
    # 接住 make/Yosys/STA 的输出，终端只留扫描进度。
    work.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        [
            "make",
            "-C",
            str(RTL_DIR),
            "perf",
            f"TOP={DESIGN}",
            f"CLK_PORT_NAME={CLK_PORT_NAME}",
            f"CLK_FREQ_MHZ={CLK_FREQ_MHZ}",
            f"PDK={PDK}",
            f"PERF_OUT={work.resolve()}",
            f"SLANG_PARAMS={slang_params(block_bytes, sets, ways, policy)}",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if completed.returncode != 0:
        lines = (completed.stdout or "").splitlines()
        tail = "\n".join(lines[-_LOG_TAIL_LINES:])
        detail = f"\n{tail}" if tail else ""
        raise RuntimeError(f"perf exited {completed.returncode}{detail}")
    found = saved(work)
    if found is None:
        raise RuntimeError(f"STA reports missing under {result_dir(work)}")
    return found
