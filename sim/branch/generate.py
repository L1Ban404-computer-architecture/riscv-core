"""在触发器预算范围内枚举 BTB 和 Bimodal BHT，只输出 JSON。"""

from itertools import product
from pathlib import Path

from sim.common.scan import argument_parser, powers_of_two, write_scan


def storage_bits(point):
    entries = point["sets"] * point["ways"]
    replacement = point["sets"] if point["policy"] == "rr" else entries
    # 每项保存 valid、tag、target[width-1:1]、kind；Bimodal 无需 backward 位。
    return (entries * (point["pc_bits"] + point["target_bits"] + 1)
            + replacement * (point["ways"] - 1).bit_length() + 2 * point["bht_entries"])


def configurations(args):
    limit = args.ff_max // (min(args.pc_bits) + min(args.target_bits) + 1)
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
                    point = dict(bht="bimodal", bht_entries=size, btb="table", sets=sets, ways=ways,
                                 policy=policy, pc_bits=pc_bits, target_bits=target_bits)
                    if args.ff_min <= storage_bits(point) <= args.ff_max:
                        yield point


def main(argv=None):
    parser = argument_parser(Path(__file__).parent, __doc__)
    # RTL 默认：4 * (10 + 15 + valid + kind) + 2 位 RR + 16 * 2 位 BHT = 142 位。
    parser.add_argument("--ff-min", type=int, default=96, help="总触发器位数下限（含 BTB、替换状态和 BHT）")
    parser.add_argument("--ff-max", type=int, default=192, help="总触发器位数上限")
    parser.add_argument("--ways-max", type=int, default=16)
    parser.add_argument("--policies", nargs="+", choices=["rr", "lru"], default=["rr"])
    parser.add_argument("--pc-bits", nargs="+", type=int, choices=range(1, 31), metavar="N",
                        default=[8, 12, 16, 20], help="PC 标签候选位宽，1..30")
    parser.add_argument("--target-bits", nargs="+", type=int, choices=range(2, 33), metavar="N",
                        default=[8, 12, 16, 20, 24], help="目标地址候选位宽，2..32")
    args = parser.parse_args(argv)
    if not 1 <= args.ff_min <= args.ff_max or args.ways_max < 2:
        parser.error("require positive ordered FF bounds and ways >= 2")
    write_scan(args, configurations(args), {
        "title": "分支预测：存储成本与误预测", "x": "total_ff", "y": "mpki",
        "color": "bht_entries", "shape": "pc_bits",
        "labels": {"total_ff": "总逻辑触发器", "mpki": "每千条指令误预测数", "bht_entries": "BHT 项数"}})


if __name__ == "__main__":
    main()
