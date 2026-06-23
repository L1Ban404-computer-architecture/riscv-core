# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

.PHONY: test wave wave-vcd

test:
	python run_riscv_core.py

wave:
	WAVES=1 TRACE_FORMAT=fst python run_riscv_core.py

wave-vcd:
	WAVES=1 TRACE_FORMAT=vcd python run_riscv_core.py
