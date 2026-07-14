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
    # FetchOutstandingDepth=1 intentionally permits a full FIFO pop/push in
    # one cycle; Verilator reports the resulting ready dependency as UNOPTFLAT.
    "-Wno-UNOPTFLAT",
]


CORE_CONFIGS = [
    ("fetch1_ifq2_mem1", {}, None),
    (
        "fetch1_ifq1_mem1",
        {
            "FetchOutstandingDepth": 1,
            "IfIdQueueDepth": 1,
            "MemOutstandingDepth": 1,
        },
        "zero_latency_core_bus_and_pipeline_flow",
    ),
    (
        "fetch4_ifq1_mem1",
        {
            "FetchOutstandingDepth": 4,
            "IfIdQueueDepth": 1,
            "MemOutstandingDepth": 1,
        },
        "randomized_core_bus_backpressure",
    ),
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


def test_riscv_core():
    repo_root = Path(__file__).resolve().parents[2]
    runner = get_runner("verilator")
    trace_format = wave_format()
    waves = trace_format is not None

    build_args = list(VERILATOR_BUILD_ARGS)
    if waves:
        build_args.append("--trace-structs")
    if waves and trace_format == "fst":
        build_args.append("--trace-fst")

    sources = [
        repo_root / "rtl/include/riscv_core_pkg.sv",
        repo_root / "rtl/common/fall_through_register.sv",
        repo_root / "rtl/common/peek_fifo.sv",
        repo_root / "rtl/common/stream_fifo.sv",
        repo_root / "rtl/common/stream_register.sv",
        repo_root / "rtl/core/units/alu.sv",
        repo_root / "rtl/core/units/branch_unit.sv",
        repo_root / "rtl/core/units/csr_unit.sv",
        repo_root / "rtl/core/units/decoder.sv",
        repo_root / "rtl/core/units/forwarding_unit.sv",
        repo_root / "rtl/core/units/imm_gen.sv",
        repo_root / "rtl/core/units/load_data_unit.sv",
        repo_root / "rtl/core/units/regfile.sv",
        repo_root / "rtl/core/units/store_data_unit.sv",
        repo_root / "rtl/core/pipe/if_stage.sv",
        repo_root / "rtl/core/pipe/id_stage.sv",
        repo_root / "rtl/core/pipe/ex_stage.sv",
        repo_root / "rtl/core/pipe/mem_stage.sv",
        repo_root / "rtl/core/pipe/wb_stage.sv",
        repo_root / "rtl/core/riscv_core_impl.sv",
        repo_root / "rtl/core/riscv_core.sv",
        repo_root / "tests/riscv_core/riscv_core_tb.sv",
    ]

    configs = CORE_CONFIGS[:1] if waves else CORE_CONFIGS
    for name, parameters, test_filter in configs:
        build_dir = repo_root / "build/tests/riscv_core" / name
        test_args = []
        if waves:
            test_args.extend(["--trace-file", str(build_dir / f"dump.{trace_format}")])

        runner.build(
            sources=sources,
            includes=[repo_root / "rtl/include"],
            hdl_toplevel="riscv_core_tb",
            build_dir=build_dir,
            build_args=build_args,
            parameters=parameters,
            always=True,
            waves=waves,
        )

        results_xml = build_dir / "results.xml"
        runner.test(
            hdl_toplevel="riscv_core_tb",
            test_module="test_riscv_core",
            build_dir=build_dir,
            test_dir=repo_root / "tests/riscv_core",
            results_xml=results_xml,
            test_filter=test_filter,
            test_args=test_args,
            waves=waves,
        )

        results = ET.parse(results_xml).getroot()
        failures = results.findall(".//failure") + results.findall(".//error")
        if failures:
            raise RuntimeError(
                f"CPU core config {name} reported {len(failures)} failure(s)"
            )


if __name__ == "__main__":
    test_riscv_core()
