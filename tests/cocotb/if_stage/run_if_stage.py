# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

from pathlib import Path

from cocotb_tools.runner import get_runner


VERILATOR_BUILD_ARGS = [
    "-Wno-PINCONNECTEMPTY",
    "-Wno-IMPORTSTAR",
    "-Wno-UNUSEDPARAM",
    "-Wno-SYNCASYNCNET",
    "-Wno-UNOPTFLAT",
]

DEPTH_CONFIGS = [
    ("default", {"FetchOutstandingDepth": 4, "IfIdQueueDepth": 2}, None),
    ("min_depth", {"FetchOutstandingDepth": 1, "IfIdQueueDepth": 1}, "parameterized_depth_smoke"),
    ("mixed_depth", {"FetchOutstandingDepth": 4, "IfIdQueueDepth": 1}, "parameterized_depth_smoke"),
]


def test_if_stage():
    repo_root = Path(__file__).resolve().parents[3]
    runner = get_runner("verilator")

    sources = [
        repo_root / "rtl/include/riscv_core_pkg.sv",
        repo_root / "third_party/ip/common_cells/src/fifo_v3.sv",
        repo_root / "third_party/ip/common_cells/src/stream_fifo.sv",
        repo_root / "third_party/ip/common_cells/src/fall_through_register.sv",
        repo_root / "rtl/core/pipe/if_stage.sv",
        repo_root / "tests/cocotb/if_stage/if_stage_tb.sv",
    ]

    for name, parameters, test_filter in DEPTH_CONFIGS:
        build_dir = repo_root / "build/cocotb/if_stage" / name

        runner.build(
            sources=sources,
            includes=[repo_root / "third_party/ip/common_cells/include"],
            hdl_toplevel="if_stage_tb",
            build_dir=build_dir,
            build_args=VERILATOR_BUILD_ARGS,
            parameters=parameters,
            always=True,
        )

        runner.test(
            hdl_toplevel="if_stage_tb",
            test_module="test_if_stage",
            build_dir=build_dir,
            test_dir=repo_root / "tests/cocotb/if_stage",
            results_xml=build_dir / "results.xml",
            test_filter=test_filter,
        )


if __name__ == "__main__":
    test_if_stage()
