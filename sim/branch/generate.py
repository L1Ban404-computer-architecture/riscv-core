"""在触发器预算范围内枚举 BTB、独立 JAL BTB 和 Bimodal BHT，只输出 JSON。"""

from itertools import product
from pathlib import Path

from sim.common.scan import argument_parser, powers_of_two, write_scan


def storage_bits(point):
    entries = point["sets"] * point["ways"]
    replacement = point["sets"] if point["policy"] == "rr" else entries
    # 独立表不保存 kind；Bimodal 无需 backward 位。
    entry_bits = point["pc_bits"] + point["target_bits"]
    bits = (entries * (entry_bits + (not point["jal_btb"]))
            + replacement * (point["ways"] - 1).bit_length() + 2 * point["bht_entries"])
    if point["jal_btb"]:
        jal_entries = point["jal_btb_entries"]
        jal_replacement = 1 if point["policy"] == "rr" else jal_entries
        bits += jal_entries * entry_bits + jal_replacement * (jal_entries - 1).bit_length()
    return bits


def configurations(args):
    limit = args.ff_max // (min(args.pc_bits) + min(args.target_bits))
    for sets in powers_of_two(limit):
        for ways in powers_of_two(min(limit // sets, args.ways_max)):
            if ways < 2:
                continue
            for size in powers_of_two(args.ff_max // 2):
                if size < 2:
                    continue
                # RTL 的 PC 标签必须同时覆盖 BTB 组索引和 BHT 索引。
                pc_min = max((sets - 1).bit_length(), (size - 1).bit_length())
                for policy, pc_bits, target_bits in product(
                        args.policies, args.pc_bits, args.target_bits):
                    if pc_bits < pc_min:
                        continue
                    for jal_btb in args.jal_btb:
                        for jal_entries in args.jal_btb_entries if jal_btb else [0]:
                            point = dict(bht="bimodal", bht_entries=size, btb="table", sets=sets, ways=ways,
                                         policy=policy, pc_bits=pc_bits, target_bits=target_bits,
                                         jal_btb=bool(jal_btb), jal_btb_entries=jal_entries)
                            if args.ff_min <= storage_bits(point) <= args.ff_max:
                                yield point


def main(argv=None):
    parser = argument_parser(Path(__file__).parent, __doc__)
    # RTL 默认：4 * 24 位分支项 + 2 位 RR + 1 * 24 位 JAL 项 + 16 * 2 位 BHT = 154 位。
    parser.add_argument("--ff-min", type=int, default=96, help="总触发器位数下限（含 BTB、替换状态和 BHT）")
    parser.add_argument("--ff-max", type=int, default=192, help="总触发器位数上限")
    parser.add_argument("--ways-max", type=int, default=16)
    parser.add_argument("--policies", nargs="+", choices=["rr", "lru"], default=["rr"])
    parser.add_argument("--jal-btb", nargs="+", type=int, choices=[0, 1], default=[0, 1],
                        help="JAL 是否使用独立全相联 BTB：0 共用，1 独立；默认同时扫描")
    parser.add_argument("--jal-btb-entries", nargs="+", type=int, default=[1, 2], metavar="N",
                        help="独立 JAL BTB 的候选表项数，沿用 BTB 替换策略和位宽；共用时忽略")
    parser.add_argument("--pc-bits", nargs="+", type=int, choices=range(1, 31), metavar="N",
                        default=[8, 10, 12, 14], help="PC 标签候选位宽，1..30")
    parser.add_argument("--target-bits", nargs="+", type=int, choices=range(2, 33), metavar="N",
                        default=[8, 10, 12, 14, 16], help="目标地址候选位宽，2..32")
    args = parser.parse_args(argv)
    if not 1 <= args.ff_min <= args.ff_max or args.ways_max < 2:
        parser.error("require positive ordered FF bounds and ways >= 2")
    if any(size < 1 or size > 0xffffffff for size in args.jal_btb_entries):
        parser.error("jal-btb-entries must be positive uint32 values")
    write_scan(args, configurations(args), {
        "title": "分支预测：存储成本与误预测", "x": "total_ff", "y": "mpki",
        "color": "bht_entries", "shape": "pc_bits",
        "labels": {"total_ff": "总逻辑触发器", "mpki": "每千条指令误预测数", "bht_entries": "BHT 项数"}})


if __name__ == "__main__":
    main()
