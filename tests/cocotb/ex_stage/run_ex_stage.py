# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

from pathlib import Path
import os
import xml.etree.ElementTree as ET

from cocotb_tools.runner import get_runner


VERILATOR_BUILD_ARGS = [
    "-Wno-IMPORTSTAR",
    "-Wno-UNUSEDSIGNAL",
    "-Wno-SYNCASYNCNET",
]


def env_flag(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.lower() in ("1", "true", "yes", "on")


def test_ex_stage():
    repo_root = Path(__file__).resolve().parents[3]
    build_dir = repo_root / "build/cocotb/ex_stage"
    runner = get_runner("verilator")
    waves = env_flag("WAVES")
    trace_format = os.environ.get("TRACE_FORMAT", "fst").lower()
    if trace_format not in ("fst", "vcd"):
        raise ValueError("TRACE_FORMAT must be 'fst' or 'vcd'")
    if not waves:
        os.environ.pop("WAVES", None)

    build_args = list(VERILATOR_BUILD_ARGS)
    if waves:
        build_args.append("--trace-structs")
    if waves and trace_format == "fst":
        build_args.append("--trace-fst")

    runner.build(
        sources=[
            repo_root / "rtl/include/riscv_core_pkg.sv",
            repo_root / "rtl/core/units/alu.sv",
            repo_root / "rtl/core/units/branch_unit.sv",
            repo_root / "rtl/core/units/forwarding_unit.sv",
            repo_root / "third_party/ip/common_cells/src/stream_register.sv",
            repo_root / "rtl/core/pipe/ex_stage.sv",
            repo_root / "tests/cocotb/ex_stage/ex_stage_tb.sv",
        ],
        includes=[
            repo_root / "rtl/include",
            repo_root / "third_party/ip/common_cells/include",
        ],
        hdl_toplevel="ex_stage_tb",
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
        hdl_toplevel="ex_stage_tb",
        test_module="test_ex_stage",
        build_dir=build_dir,
        test_dir=repo_root / "tests/cocotb/ex_stage",
        results_xml=results_xml,
        test_args=test_args,
        waves=waves,
    )

    results = ET.parse(results_xml).getroot()
    failures = results.findall(".//failure") + results.findall(".//error")
    if failures:
        raise RuntimeError(f"EX Stage regression reported {len(failures)} failure(s)")


if __name__ == "__main__":
    test_ex_stage()
