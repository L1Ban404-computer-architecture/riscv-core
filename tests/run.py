# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import argparse
import os
from dataclasses import dataclass, field
from pathlib import Path
import xml.etree.ElementTree as ET

from cocotb_tools.runner import get_runner


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL_PACKAGE = "rtl/include/riscv_core_pkg.sv"
FIFO_RTL = [
    "rtl/common/stream_fifo.sv",
    "rtl/common/stream_register.sv",
    "rtl/common/fall_through_register.sv",
]
UNIT_RTL = [
    "rtl/core/units/alu.sv",
    "rtl/core/units/branch_unit.sv",
    "rtl/core/units/csr_unit.sv",
    "rtl/core/units/decoder.sv",
    "rtl/core/units/forwarding_unit.sv",
    "rtl/core/units/imm_gen.sv",
    "rtl/core/units/load_data_unit.sv",
    "rtl/core/units/regfile.sv",
    "rtl/core/units/store_data_unit.sv",
]
PIPE_RTL = [
    "rtl/core/pipe/if_stage.sv",
    "rtl/core/pipe/id_stage.sv",
    "rtl/core/pipe/ex_stage.sv",
    "rtl/core/pipe/mem_stage.sv",
    "rtl/core/pipe/wb_stage.sv",
]
COMMON_BUILD_ARGS = [
    "-Wno-PINCONNECTEMPTY",
    "-Wno-IMPORTSTAR",
    "-Wno-SYNCASYNCNET",
    # CoreBus permits zero-latency request/response, which creates intentional
    # combinational ready paths through fall-through buffers.
    "-Wno-UNOPTFLAT",
]


@dataclass(frozen=True)
class Variant:
    name: str = "default"
    parameters: dict[str, int] = field(default_factory=dict)
    test_filter: str | None = None


@dataclass(frozen=True)
class Suite:
    top: str
    test_module: str
    sources: list[str]
    variants: list[Variant] = field(default_factory=lambda: [Variant()])


SUITES = {
    "common_fifo": Suite(
        top="common_fifo_tb",
        test_module="test_common_fifo",
        sources=["rtl/common/stream_fifo.sv", "tests/common_fifo/common_fifo_tb.sv"],
        variants=[
            Variant(
                f"d{depth}_ft{fall_through}_rw{same_cycle_rw}",
                {
                    "Depth": depth,
                    "FallThrough": fall_through,
                    "SameCycleRW": same_cycle_rw,
                },
            )
            for depth in (1, 3)
            for fall_through in (0, 1)
            for same_cycle_rw in (0, 1)
        ],
    ),
    "corebus_axi4": Suite(
        top="corebus_axi4",
        test_module="test_corebus_axi4",
        sources=["rtl/core/corebus_axi4.sv"],
    ),
    "if_stage": Suite(
        top="if_stage_tb",
        test_module="test_if_stage",
        sources=[
            RTL_PACKAGE,
            "rtl/common/stream_fifo.sv",
            "rtl/common/fall_through_register.sv",
            "rtl/core/pipe/if_stage.sv",
            "tests/if_stage/if_stage_tb.sv",
        ],
        variants=[
            Variant("fetch1_ifq2", {"FetchOutstandingDepth": 1, "IfIdQueueDepth": 2}),
            Variant(
                "fetch1_ifq1",
                {"FetchOutstandingDepth": 1, "IfIdQueueDepth": 1},
                "parameterized_depth_smoke",
            ),
            Variant(
                "fetch4_ifq1",
                {"FetchOutstandingDepth": 4, "IfIdQueueDepth": 1},
                "parameterized_depth_smoke",
            ),
        ],
    ),
    "id_stage": Suite(
        top="id_stage_tb",
        test_module="test_id_stage",
        sources=[
            RTL_PACKAGE,
            "rtl/core/units/decoder.sv",
            "rtl/core/units/imm_gen.sv",
            "rtl/core/units/regfile.sv",
            *FIFO_RTL[:2],
            "rtl/core/pipe/id_stage.sv",
            "tests/id_stage/id_stage_tb.sv",
        ],
    ),
    "ex_stage": Suite(
        top="ex_stage_tb",
        test_module="test_ex_stage",
        sources=[
            RTL_PACKAGE,
            "rtl/core/units/alu.sv",
            "rtl/core/units/branch_unit.sv",
            "rtl/core/units/forwarding_unit.sv",
            *FIFO_RTL[:2],
            "rtl/core/pipe/ex_stage.sv",
            "tests/ex_stage/ex_stage_tb.sv",
        ],
    ),
    "mem_stage": Suite(
        top="mem_stage_tb",
        test_module="test_mem_stage",
        sources=[
            RTL_PACKAGE,
            *FIFO_RTL,
            "rtl/core/units/store_data_unit.sv",
            "rtl/core/units/load_data_unit.sv",
            "rtl/core/pipe/mem_stage.sv",
            "tests/mem_stage/mem_stage_tb.sv",
        ],
    ),
    "wb_stage": Suite(
        top="wb_stage_tb",
        test_module="test_wb_stage",
        sources=[
            RTL_PACKAGE,
            "rtl/core/units/csr_unit.sv",
            "rtl/core/pipe/wb_stage.sv",
            "tests/wb_stage/wb_stage_tb.sv",
        ],
    ),
    "riscv_core": Suite(
        top="riscv_core_tb",
        test_module="test_riscv_core",
        sources=[
            RTL_PACKAGE,
            *FIFO_RTL,
            *UNIT_RTL,
            *PIPE_RTL,
            "rtl/core/riscv_core_impl.sv",
            "tests/riscv_core/riscv_core_tb.sv",
        ],
        variants=[
            Variant("fetch1_ifq2", {}),
            Variant(
                "fetch1_ifq1",
                {"FetchOutstandingDepth": 1, "IfIdQueueDepth": 1},
                "zero_latency_core_bus_and_pipeline_flow",
            ),
            Variant(
                "fetch4_ifq1",
                {"FetchOutstandingDepth": 4, "IfIdQueueDepth": 1},
                "randomized_core_bus_backpressure",
            ),
        ],
    ),
}


def wave_format() -> str | None:
    value = os.environ.get("WAVE", "").lower()
    if not value:
        os.environ.pop("WAVES", None)
        return None
    if value not in ("fst", "vcd"):
        raise ValueError("WAVE must be empty, 'fst', or 'vcd'")
    os.environ["WAVES"] = "1"
    return value


def run_suite(name: str) -> None:
    suite = SUITES[name]
    trace_format = wave_format()
    waves = trace_format is not None
    variants = suite.variants[:1] if waves else suite.variants
    runner = get_runner("verilator")

    for variant in variants:
        build_dir = REPO_ROOT / "build/tests" / name
        if len(suite.variants) > 1:
            build_dir /= variant.name

        build_args = list(COMMON_BUILD_ARGS)
        if waves:
            build_args.append("--trace-structs")
        if trace_format == "fst":
            build_args.append("--trace-fst")

        runner.build(
            sources=[REPO_ROOT / source for source in suite.sources],
            includes=[REPO_ROOT / "rtl/include"],
            hdl_toplevel=suite.top,
            build_dir=build_dir,
            build_args=build_args,
            parameters=variant.parameters,
            always=True,
            waves=waves,
        )

        test_args = []
        if trace_format:
            test_args.extend(["--trace-file", str(build_dir / f"dump.{trace_format}")])

        results_xml = build_dir / "results.xml"
        runner.test(
            hdl_toplevel=suite.top,
            test_module=suite.test_module,
            test_dir=REPO_ROOT / "tests" / name,
            build_dir=build_dir,
            results_xml=results_xml,
            test_filter=variant.test_filter,
            test_args=test_args,
            waves=waves,
        )

        results = ET.parse(results_xml).getroot()
        failures = results.findall(".//failure") + results.findall(".//error")
        if failures:
            raise RuntimeError(
                f"{name}/{variant.name} reported {len(failures)} failure(s)"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("suite", choices=sorted(SUITES))
    args = parser.parse_args()
    run_suite(args.suite)


if __name__ == "__main__":
    main()
