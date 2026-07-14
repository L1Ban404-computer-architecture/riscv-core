# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

from pathlib import Path
import os
import xml.etree.ElementTree as ET

from cocotb_tools.runner import get_runner


VERILATOR_BUILD_ARGS = [
    "-Wno-IMPORTSTAR",
]


def wave_format() -> str | None:
    value = os.environ.get("WAVE", "").lower()
    if value == "":
        os.environ.pop("WAVES", None)
        return None
    if value not in ("fst", "vcd"):
        raise ValueError("WAVE must be empty, 'fst', or 'vcd'")
    os.environ["WAVES"] = "1"
    return value


def test_wb_stage():
    repo_root = Path(__file__).resolve().parents[2]
    build_dir = repo_root / "build/tests/wb_stage"
    runner = get_runner("verilator")
    trace_format = wave_format()
    waves = trace_format is not None

    build_args = list(VERILATOR_BUILD_ARGS)
    if waves:
        build_args.append("--trace-structs")
    if waves and trace_format == "fst":
        build_args.append("--trace-fst")

    runner.build(
        sources=[
            repo_root / "rtl/include/riscv_core_pkg.sv",
            repo_root / "rtl/core/units/csr_unit.sv",
            repo_root / "rtl/core/pipe/wb_stage.sv",
            repo_root / "tests/wb_stage/wb_stage_tb.sv",
        ],
        includes=[repo_root / "rtl/include"],
        hdl_toplevel="wb_stage_tb",
        build_dir=build_dir,
        build_args=build_args,
        always=True,
        waves=waves,
    )

    test_args = []
    if waves:
        test_args.extend(["--trace-file", str(build_dir / f"dump.{trace_format}")])

    results_xml = build_dir / "results.xml"
    runner.test(
        hdl_toplevel="wb_stage_tb",
        test_module="test_wb_stage",
        build_dir=build_dir,
        test_dir=repo_root / "tests/wb_stage",
        results_xml=results_xml,
        test_args=test_args,
        waves=waves,
    )

    results = ET.parse(results_xml).getroot()
    failures = results.findall(".//failure") + results.findall(".//error")
    if failures:
        raise RuntimeError(f"WB Stage regression reported {len(failures)} failure(s)")


if __name__ == "__main__":
    test_wb_stage()
