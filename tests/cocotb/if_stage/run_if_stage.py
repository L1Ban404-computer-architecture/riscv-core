# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

from pathlib import Path
import os

from cocotb_tools.runner import get_runner


VERILATOR_BUILD_ARGS = [
    "-Wno-PINCONNECTEMPTY",
    "-Wno-IMPORTSTAR",
    "-Wno-UNUSEDPARAM",
    "-Wno-SYNCASYNCNET",
    "-Wno-UNOPTFLAT",
]

DEPTH_CONFIGS = [
    ("fetch4_ifq2", {"FetchOutstandingDepth": 4, "IfIdQueueDepth": 2}, None),
    ("fetch1_ifq1", {"FetchOutstandingDepth": 1, "IfIdQueueDepth": 1}, "parameterized_depth_smoke"),
    ("fetch4_ifq1", {"FetchOutstandingDepth": 4, "IfIdQueueDepth": 1}, "parameterized_depth_smoke"),
]


def env_flag(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.lower() in ("1", "true", "yes", "on")


def test_if_stage():
    repo_root = Path(__file__).resolve().parents[3]
    runner = get_runner("verilator")
    waves = env_flag("WAVES")
    trace_format = os.environ.get("TRACE_FORMAT", "fst").lower()
    if trace_format not in ("fst", "vcd"):
        raise ValueError("TRACE_FORMAT must be 'fst' or 'vcd'")
    if not waves:
        # cocotb runner treats a present WAVES environment variable as true in
        # the Verilator build step, even when it is set to "0".
        os.environ.pop("WAVES", None)

    build_args = list(VERILATOR_BUILD_ARGS)
    if waves:
        build_args.append("--trace-structs")
    if waves and trace_format == "fst":
        build_args.append("--trace-fst")

    sources = [
        repo_root / "rtl/include/riscv_core_pkg.sv",
        repo_root / "third_party/ip/common_cells/src/fifo_v3.sv",
        repo_root / "third_party/ip/common_cells/src/stream_fifo.sv",
        repo_root / "third_party/ip/common_cells/src/fall_through_register.sv",
        repo_root / "rtl/core/pipe/if_stage.sv",
        repo_root / "tests/cocotb/if_stage/if_stage_tb.sv",
    ]

    configs = DEPTH_CONFIGS[:1] if waves else DEPTH_CONFIGS
    wave_dir = repo_root / "build/cocotb/if_stage"

    for name, parameters, test_filter in configs:
        build_dir = repo_root / "build/cocotb/if_stage" / name
        test_args = []
        if waves:
            test_args.extend(["--trace-file", str(wave_dir / f"dump.{trace_format}")])

        runner.build(
            sources=sources,
            includes=[repo_root / "third_party/ip/common_cells/include"],
            hdl_toplevel="if_stage_tb",
            build_dir=build_dir,
            build_args=build_args,
            parameters=parameters,
            always=True,
            waves=waves,
        )

        runner.test(
            hdl_toplevel="if_stage_tb",
            test_module="test_if_stage",
            build_dir=build_dir,
            test_dir=repo_root / "tests/cocotb/if_stage",
            results_xml=build_dir / "results.xml",
            test_filter=test_filter,
            test_args=test_args,
            waves=waves,
        )


if __name__ == "__main__":
    test_if_stage()
