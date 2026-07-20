from pathlib import Path
import os

from cocotb_tools.runner import get_runner


def test_corebus_axi4():
    repo_root = Path(__file__).resolve().parents[2]
    build_dir = repo_root / "build/tests/corebus_axi4"
    runner = get_runner("verilator")
    waves = os.environ.get("WAVE", "") != ""
    runner.build(
        sources=[repo_root / "rtl/core/corebus_axi4.sv"],
        hdl_toplevel="corebus_axi4",
        build_dir=build_dir,
        always=True,
        waves=waves,
    )
    runner.test(
        hdl_toplevel="corebus_axi4",
        test_module="test_corebus_axi4",
        build_dir=build_dir,
        test_dir=Path(__file__).parent,
        waves=waves,
    )


if __name__ == "__main__":
    test_corebus_axi4()
