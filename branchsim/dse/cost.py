"""逻辑存储成本：通用 BTB 格式与历史/当前紧凑 RTL 格式。"""

from typing import Dict


def generic_btb_bits(point: tuple) -> Dict[str, int]:
    """设计声明的触发器位数；软件容器大小不参与硬件成本。"""
    bht, btb, sets, ways, policy, pc_bits, target_bits = point[:7]
    if btb == "none":
        return {"entry_bits": 0, "replacement_bits": 0, "btb_ff": 0, "bht_ff": 0, "total_ff": 0}
    if bht == "bimodal" and (len(point) != 8 or point[7] < 1 or (point[7] & (point[7] - 1)) != 0):
        raise ValueError("bimodal point requires a positive power-of-two BHT size")
    entries = sets * ways
    # 每项除两个 PC 字段外，还有 valid、分支类型和原始前后向各一位。
    entry_bits = pc_bits + target_bits + 3
    replacement_bits = (sets if policy == "rr" else entries) * (ways - 1).bit_length()
    btb_ff = entries * entry_bits + replacement_bits
    bht_ff = 2 * point[7] if bht == "bimodal" else 0
    return {"entry_bits": entry_bits, "replacement_bits": replacement_bits,
            "btb_ff": btb_ff, "bht_ff": bht_ff, "total_ff": btb_ff + bht_ff}


def predictor_bits(config, *, aligned_jal=False):
    """B/J 目标固定 T16；当前格式省去 JAL bit1，历史格式保留该位。"""
    depth = config["depth"]
    ras = depth * (config["width"] - 2) + (depth - 1).bit_length() + depth.bit_length() if depth else 0
    bits = ras + 2 * config["bht_entries"]
    bits += config["sets"] * (config["ways"] - 1).bit_length()
    count = config["sets"] * config["ways"]
    tag = config["pc_bits"]
    if config.get("layout", "unified") == "unified":
        kind = 2 if depth and config["mode"] == "btb" else 1
        bits += count * (1 + tag + 15 + kind)
    else:
        bits += count * (1 + tag + 15)
        jumps = config["jump_sets"] * config["jump_ways"]
        kind = int(bool(depth and config["mode"] == "btb"))
        bits += jumps * (1 + tag + (14 if aligned_jal else 15) + kind)
        bits += config["jump_sets"] * (config["jump_ways"] - 1).bit_length()
    if depth and config["mode"] == "filter":
        size = config["filters"]
        ret_tag = config.get("ret_tag_bits", 0) or tag
        bits += size * (1 + ret_tag) + (size - 1).bit_length()
    return bits


def compact_predictor_bits(config):
    return predictor_bits(config, aligned_jal=True)
