# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

from pathlib import Path
import xml.etree.ElementTree as ET

from cocotb_tools.runner import get_runner


CONFIGS = [
    (
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
]


def test_common_fifo():
    repo_root = Path(__file__).resolve().parents[3]
    runner = get_runner("verilator")

    for name, parameters in CONFIGS:
        build_dir = repo_root / "build/cocotb/common_fifo" / name
        runner.build(
            sources=[
                repo_root / "rtl/common/peek_fifo.sv",
                repo_root / "rtl/common/stream_fifo.sv",
                repo_root / "tests/cocotb/common_fifo/common_fifo_tb.sv",
            ],
            includes=[repo_root / "rtl/include"],
            hdl_toplevel="common_fifo_tb",
            build_dir=build_dir,
            build_args=["-Wno-UNUSEDSIGNAL", "-Wno-SYNCASYNCNET"],
            parameters=parameters,
            always=True,
        )

        results_xml = build_dir / "results.xml"
        runner.test(
            hdl_toplevel="common_fifo_tb",
            test_module="test_common_fifo",
            build_dir=build_dir,
            test_dir=repo_root / "tests/cocotb/common_fifo",
            results_xml=results_xml,
        )

        results = ET.parse(results_xml).getroot()
        failures = results.findall(".//failure") + results.findall(".//error")
        if failures:
            raise RuntimeError(
                f"Common FIFO config {name} reported {len(failures)} failure(s)"
            )


if __name__ == "__main__":
    test_common_fifo()
