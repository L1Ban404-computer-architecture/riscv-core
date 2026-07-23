# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

ALL ?= $(sort $(notdir $(patsubst %/,%,$(dir $(wildcard tests/*/test_*.py)))))
TEST_SUITES := $(foreach test,$(ALL),$(patsubst tests/%,%,$(patsubst %/,%,$(test))))
PYTHON ?= python
VERILATOR ?= verilator
VERILATOR_BUILD_DIR ?= build/verilator
VERILATOR_PREFIX ?= core
VERILATOR_WARNINGS := -Wno-PINCONNECTEMPTY -Wno-IMPORTSTAR \
	-Wno-SYNCASYNCNET -Wno-UNOPTFLAT

.PHONY: test lint verilator check

test:
	@for suite in $(TEST_SUITES); do \
		echo "==> tests/$$suite"; \
		WAVE=$(WAVE) $(PYTHON) tests/run.py $$suite || exit $$?; \
	done

lint:
	$(VERILATOR) --lint-only --sv --Wall $(VERILATOR_WARNINGS) \
		-f .slang/riscv_core.f

verilator:
	$(VERILATOR) --cc --build --sv $(VERILATOR_WARNINGS) \
		--Mdir $(VERILATOR_BUILD_DIR) \
		--top-module ysyx_25080230 \
		--prefix $(VERILATOR_PREFIX) \
		-f .slang/riscv_core.f

check: lint test verilator
