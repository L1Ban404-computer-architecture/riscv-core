"""回放、输入指纹和结果校验；不计算硬件成本。"""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
from typing import Dict

GROUPS = ("total", "control_flow", "non_control_flow", "actual_taken", "actual_not_taken",
          "predicted_taken", "predicted_not_taken")


def parse_output(output: str) -> Dict[str, object]:
    """用整数计数重算比率，避免把模拟器打印的六位小数当作原始精度。"""
    lines = {}
    instructions = None
    for line in output.splitlines():
        cells = line.split()
        if not cells:
            continue
        if cells[0].startswith("instructions="):
            instructions = int(cells[0].split("=", 1)[1])
        elif cells[0] in (*GROUPS, "direction"):
            if cells[0] in lines:
                raise ValueError(f"duplicate statistics: {cells[0]}")
            lines[cells[0]] = dict(cell.split("=", 1) for cell in cells[1:])
    if instructions is None or instructions < 0:
        raise ValueError("missing/invalid instruction count")
    row: Dict[str, object] = {"instructions": instructions}
    for group in GROUPS:
        counts = lines[group]
        accesses, hits, misses = (int(counts[key]) for key in ("accesses", "hits", "misses"))
        if min(accesses, hits, misses) < 0 or hits + misses != accesses:
            raise ValueError(f"inconsistent {group} counts")
        row.update({f"{group}_accesses": accesses, f"{group}_hits": hits,
                    f"{group}_misses": misses,
                    f"{group}_hit_rate": hits / accesses if accesses else "-"})
    accesses = int(row["total_accesses"])
    hits = int(row["total_hits"])
    if accesses != instructions:
        raise ValueError("total observations must include every retired instruction")
    for pair in (("actual_taken", "actual_not_taken"),
                 ("predicted_taken", "predicted_not_taken"),
                 ("control_flow", "non_control_flow")):
        for metric in ("accesses", "hits", "misses"):
            if sum(int(row[f"{group}_{metric}"]) for group in pair) != row[f"total_{metric}"]:
                raise ValueError(f"inconsistent {pair} partition")
    direction_hits = int(lines["direction"]["hits"])
    if not hits <= direction_hits <= accesses:
        raise ValueError("inconsistent direction hits")
    row["direction_hits"] = direction_hits
    row["direction_hit_rate"] = direction_hits / accesses if accesses else "-"
    row["mpki"] = 1000 * int(row["total_misses"]) / instructions if instructions else "-"
    return row


def fingerprint(path: Path) -> dict:
    before = path.stat()
    with path.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise RuntimeError(f"input changed while hashing: {path}")
    return {"path": str(path), "bytes": after.st_size, "mtime_ns": after.st_mtime_ns,
            "sha256": digest}


def replay(binary, trace, output, point):
    name, config = point
    config = {"layout": "unified", "jump_sets": 0, "jump_ways": 0, "priority": "jump", **config}
    command = [str(binary), "--trace", str(trace), "--bht", "bimodal",
               "--bht-entries", str(config["bht_entries"]), "--btb-sets", str(config["sets"]),
               "--btb-ways", str(config["ways"]), "--pc-bits", str(config["pc_bits"]),
               "--target-bits", "16", "--ras-entries", str(config["depth"]),
               "--ras-target-bits", str(config["width"]), "--ras-mode", config["mode"]]
    command += ["--btb-layout", config["layout"], "--split-priority", config["priority"]]
    command += ["--ret-priority", config.get("ret_priority", "ret")]
    if config["layout"] == "split":
        command += ["--jump-btb-sets", str(config["jump_sets"]), "--jump-btb-ways", str(config["jump_ways"])]
    if config["mode"] == "filter":
        command += ["--ras-filter-entries", str(config["filters"])]
        command += ["--ras-filter-pc-bits", str(config.get("ret_tag_bits", 0))]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / f"{name}.log").write_text(result.stdout, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"{name}: exit {result.returncode}; see log")
    return read_result(result.stdout, point)


def read_result(output, point):
    """回读原始日志，校验实际参数；供网格扫描安全复用同一输入的结果。"""
    name, config = point
    config = {"layout": "unified", "jump_sets": 0, "jump_ways": 0, "priority": "jump", **config}
    headers = [dict(cell.split("=", 1) for cell in line.split()[1:])
               for line in output.splitlines() if line.startswith("config ")]
    expected_header = {"bht": "bimodal", "btb": "table", "btb_sets": str(config["sets"]),
                       "btb_ways": str(config["ways"]), "pc_bits": str(config["pc_bits"]),
                       "target_bits": "16", "btb_policy": "rr", "bht_entries": str(config["bht_entries"])}
    if len(headers) != 1 or any(headers[0].get(key) != value for key, value in expected_header.items()):
        raise ValueError(f"{name}: wrong predictor config")
    stats = parse_output(output)
    extra = {}
    for line in output.splitlines():
        cells = line.split()
        if cells and cells[0] in ("ras", "return_table", "returns", "other_jalr", "branches", "jals", "redirects", "btb_layout"):
            extra[cells[0]] = dict(cell.split("=", 1) for cell in cells[1:])
    expected = {"entries": str(config["depth"]), "target_bits": str(config["width"]), "mode": config["mode"]}
    if any(extra["ras"][key] != value for key, value in expected.items()):
        raise ValueError(f"{name}: wrong RAS config")
    layout = extra["btb_layout"]
    expected_layout = {"mode": config["layout"], "jump_sets": str(config["jump_sets"]),
                       "jump_ways": str(config["jump_ways"]), "priority": config["priority"]}
    if any(layout[key] != value for key, value in expected_layout.items()):
        raise ValueError(f"{name}: wrong BTB layout")
    stats["btb_conflicts"] = int(layout["conflicts"])
    for group in ("returns", "other_jalr", "branches", "jals"):
        counts = {key: int(value) for key, value in extra[group].items()}
        if min(counts.values()) < 0 or counts["hits"] + counts["misses"] != counts["accesses"]:
            raise ValueError(f"{name}: inconsistent {group}")
        stats.update({f"{group}_{key}": value for key, value in counts.items()})
    for key in ("accesses", "hits", "misses"):
        if sum(stats[f"{group}_{key}"] for group in ("returns", "other_jalr", "branches", "jals")) != stats[f"control_flow_{key}"]:
            raise ValueError(f"{name}: control flow partition mismatch")
    stats.update({f"ras_{key}": int(value) for key, value in extra["ras"].items() if key not in ("mode",)})
    stats["return_table_bits"] = int(extra["return_table"]["storage_bits"])
    if extra["return_table"]["priority"] != config.get("ret_priority", "ret"):
        raise ValueError(f"{name}: wrong RET priority")
    stats["return_conflicts"] = int(extra["return_table"]["conflicts"])
    stats["return_tag_bits"] = int(extra["return_table"]["tag_bits"])
    expected_tag_bits = (config.get("ret_tag_bits", 0) or config["pc_bits"]) if config["mode"] == "filter" and config["depth"] else 0
    if stats["return_tag_bits"] != expected_tag_bits:
        raise ValueError(f"{name}: wrong RET tag width")
    stats["redirects"] = int(extra["redirects"]["count"])
    return {"name": name, **config, **stats}


