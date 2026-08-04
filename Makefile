# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

VERILATOR ?= verilator
VERILATOR_BUILD_DIR ?= build/verilator
VERILATOR_PREFIX ?= core
VERILATOR_WARNINGS := -Wno-PINCONNECTEMPTY -Wno-IMPORTSTAR \
	-Wno-SYNCASYNCNET -Wno-UNOPTFLAT

.PHONY: lint verilator check

lint:
	$(VERILATOR) --lint-only --sv --Wall $(VERILATOR_WARNINGS) \
		-f .slang/riscv_core.f

verilator:
	$(VERILATOR) --cc --build --sv $(VERILATOR_WARNINGS) \
		--Mdir $(VERILATOR_BUILD_DIR) \
		--top-module ysyx_25080230 \
		--prefix $(VERILATOR_PREFIX) \
		-f .slang/riscv_core.f

check: lint verilator
