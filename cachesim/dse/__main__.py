# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

"""扫描 I-cache 几何：命中率、AMT，以及 1GHz 下的面积和频率。"""

from __future__ import annotations

import re
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

from dse.report import write_csv, write_plot
from dse.synth import PDK, synthesize

# 缺失延迟 = LAT_HEAD + LAT_BEAT * (字数 - 1)。字数是 block_bytes / 4。
LAT_HEAD = 68.0
LAT_BEAT = 43.0

CACHESIM_DIR = Path(__file__).resolve().parents[1]
CACHESIM = CACHESIM_DIR / "build" / "cachesim"
TRACE = CACHESIM_DIR / "build" / "microbench.pc"
WORK_ROOT = CACHESIM_DIR / "build" / "dse"
OUTPUT = CACHESIM_DIR / "build" / "dse.csv"
PLOT = CACHESIM_DIR / "build" / "dse.html"

# 数据容量 = sets * ways * block_bytes，单位是字节，上下限都包含。
# 组数、路数、块大小在这个区间里取所有 2 的幂组合。块至少 4 字节，路数至多 8。
# 阵列按触发器综合，容量再放大面积会很快超过 nangate45 上留给核心的预算。
BYTES_MIN = 16
BYTES_MAX = 128
POLICIES = ("fixed", "rr", "plru")
JOBS = 16

_BLOCK_MIN = 4
_WAYS_MAX = 8
_ADDR_BITS = 32

_RESULT_RE = re.compile(
    r"accesses=(?P<accesses>\d+)\s+"
    r"hits=(?P<hits>\d+)\s+"
    r"misses=(?P<misses>\d+)\s+"
    r"hit_rate=(?P<hit_rate>\S+)"
)

Point = Tuple[int, int, int, str]


def miss_penalty(block_bytes: int) -> float:
    words = block_bytes / 4
    return LAT_HEAD + LAT_BEAT * (words - 1)


def amt(hit_rate: float, penalty: float) -> float:
    return (1.0 - hit_rate) * penalty


def geom_name(sets: int, ways: int, block_bytes: int, policy: str) -> str:
    return f"s{sets}_w{ways}_b{block_bytes}_{policy}"


def replay(
    cachesim: str, trace: str, sets: int, ways: int, block_bytes: int, policy: str
) -> Dict[str, str]:
    completed = subprocess.run(
        [
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
        ],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    match = _RESULT_RE.search(completed.stdout)
    if match is None:
        raise RuntimeError(f"unrecognized cachesim output: {completed.stdout!r}")
    return match.groupdict()


def run_point(
    cachesim: str, trace: str, work_root: str, point: Point
) -> Dict[str, object]:
    sets, ways, block_bytes, policy = point
    work = Path(work_root) / PDK / geom_name(sets, ways, block_bytes, policy)

    # 面积和命中率互不依赖，先综合再回放，失败时子进程退出码直接抛出。
    freq, area = synthesize(work, sets, ways, block_bytes, policy)
    parsed = replay(cachesim, trace, sets, ways, block_bytes, policy)
    hit = None if parsed["hit_rate"] == "-" else float(parsed["hit_rate"])
    estimated = "-" if hit is None else amt(hit, miss_penalty(block_bytes))
    return {
        "sets": sets,
        "ways": ways,
        "block_bytes": block_bytes,
        "policy": policy,
        "synth_area": area,
        "synth_freq_mhz": freq,
        "hit_rate": parsed["hit_rate"],
        "amt": estimated,
    }


def _powers_of_two(limit: int) -> List[int]:
    values: List[int] = []
    value = 1
    while value <= limit:
        values.append(value)
        value *= 2
    return values


def geometries(
    bytes_min: int, bytes_max: int, policies: Sequence[str]
) -> List[Point]:
    """容量落在区间内、组/路/块都是 2 的幂、且路数不超过上限的全部组合。"""
    points: List[Point] = []
    largest = max(bytes_max // _BLOCK_MIN, 1)
    for block_bytes in _powers_of_two(bytes_max):
        if block_bytes < _BLOCK_MIN:
            continue
        offset_bits = block_bytes.bit_length() - 1
        for ways in _powers_of_two(largest):
            if ways > _WAYS_MAX:
                continue
            for sets in _powers_of_two(largest):
                capacity = sets * ways * block_bytes
                if capacity < bytes_min or capacity > bytes_max:
                    continue
                set_bits = 0 if sets == 1 else sets.bit_length() - 1
                if offset_bits + set_bits >= _ADDR_BITS:
                    continue
                points.extend(
                    (sets, ways, block_bytes, policy) for policy in policies
                )
    points.sort(key=lambda point: (point[0] * point[1] * point[2], *point))
    return points


def sort_key(row: Dict[str, object]) -> tuple:
    text = str(row["amt"])
    amt_value = float("inf") if text == "-" else float(text)
    return (
        amt_value,
        float(row["synth_area"]),
        int(row["sets"]),
        int(row["ways"]),
        int(row["block_bytes"]),
        str(row["policy"]),
    )


def main() -> int:
    points = geometries(BYTES_MIN, BYTES_MAX, POLICIES)
    if not points:
        raise RuntimeError(
            f"no power-of-two geometries in [{BYTES_MIN}, {BYTES_MAX}] bytes"
        )
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    print(f"sweep {len(points)} configs -> {OUTPUT}, {PLOT}", file=sys.stderr)

    rows: List[Dict[str, object]] = []
    with ProcessPoolExecutor(max_workers=JOBS) as pool:
        futures = [
            pool.submit(run_point, str(CACHESIM), str(TRACE), str(WORK_ROOT), point)
            for point in points
        ]
        for index, future in enumerate(as_completed(futures), start=1):
            row = future.result()
            rows.append(row)
            print(
                f"[{index}/{len(points)}] "
                f"{geom_name(int(row['sets']), int(row['ways']), int(row['block_bytes']), str(row['policy']))}",
                file=sys.stderr,
            )

    rows.sort(key=sort_key)
    write_csv(OUTPUT, rows)
    write_plot(PLOT, rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
