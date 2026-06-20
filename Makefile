# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

.PHONY: all test test-if-stage lint lint-if-stage clean clean-build

all: test

test: test-if-stage

test-if-stage:
	python tests/cocotb/if_stage/run_if_stage.py

lint: lint-if-stage

lint-if-stage:
	verilator --lint-only \
	  -Ithird_party/ip/common_cells/include \
	  rtl/include/riscv_core_pkg.sv \
	  third_party/ip/common_cells/src/fifo_v3.sv \
	  third_party/ip/common_cells/src/stream_fifo.sv \
	  third_party/ip/common_cells/src/fall_through_register.sv \
	  rtl/core/pipe/if_stage.sv \
	  tests/cocotb/if_stage/if_stage_tb.sv

clean: clean-build

clean-build:
	rm -rf build
