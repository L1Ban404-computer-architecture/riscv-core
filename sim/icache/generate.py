"""在数据容量范围内枚举 I-cache 几何，默认使用 RR，只输出 JSON。"""

import math
from pathlib import Path

from sim.common.scan import argument_parser, powers_of_two, write_scan


def configurations(args):
    largest = args.bytes_max // 4
    for block_bytes in powers_of_two(min(args.bytes_max, 64)):
        if block_bytes < 4:
            continue
        for sets in powers_of_two(largest):
            if (sets.bit_length() - 1) + (block_bytes.bit_length() - 1) >= 32:
                continue
            for ways in powers_of_two(args.ways_max):
                if args.bytes_min <= sets * ways * block_bytes <= args.bytes_max:
                    for policy in args.policies:
                        yield dict(sets=sets, ways=ways, block_bytes=block_bytes, policy=policy,
                                   miss_head_cycles=args.miss_head_cycles, miss_beat_cycles=args.miss_beat_cycles)


def main(argv=None):
    parser = argument_parser(Path(__file__).parent, __doc__)
    # RTL 默认数据容量：4 组 * 2 路 * 16 字节 = 128 字节。
    parser.add_argument("--bytes-min", type=int, default=64, help="总数据容量下限，单位为字节")
    parser.add_argument("--bytes-max", type=int, default=256, help="总数据容量上限，单位为字节")
    parser.add_argument("--ways-max", type=int, default=8)
    parser.add_argument("--policies", nargs="+", choices=["rr", "plru"], default=["rr"])
    parser.add_argument("--miss-head-cycles", type=float, default=68)
    parser.add_argument("--miss-beat-cycles", type=float, default=43)
    args = parser.parse_args(argv)
    if (args.bytes_min < 4 or args.bytes_max < args.bytes_min or not 1 <= args.ways_max <= 32 or
            not all(math.isfinite(value) and value >= 0 for value in
                    (args.miss_head_cycles, args.miss_beat_cycles))):
        parser.error("invalid capacity, ways (1..32) or latency bounds")
    write_scan(args, configurations(args), {
        "title": "I-cache：成本与平均缺失开销", "x": "synth_area",
        "y": "amt", "color": "policy", "shape": "sets",
        "labels": {"bytes": "数据容量（字节）", "synth_area": "综合面积", "amt": "平均缺失开销（周期）"}})


if __name__ == "__main__":
    main()
