# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

ALL ?= $(sort $(patsubst tests/%/,%,$(wildcard tests/*/)))
TEST_DIRS := $(foreach test,$(ALL),$(if $(filter tests/%,$(test)),$(test),tests/$(test)))
VERILATOR ?= verilator
VERILATOR_BUILD_DIR ?= build/verilator
VERILATOR_PREFIX ?= core
VERILATOR_WARNINGS := -Wno-PINCONNECTEMPTY -Wno-IMPORTSTAR \
	-Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET -Wno-UNOPTFLAT

.PHONY: test lint verilator check

test:
	@for dir in $(TEST_DIRS); do \
		echo "==> $$dir"; \
		$(MAKE) -C $$dir test WAVE=$(WAVE) || exit $$?; \
	done

lint:
	$(VERILATOR) --lint-only --sv --Wall -Wno-fatal $(VERILATOR_WARNINGS) \
		-f .slang/riscv_core.f

verilator:
	$(VERILATOR) --cc --build --sv $(VERILATOR_WARNINGS) \
		--Mdir $(VERILATOR_BUILD_DIR) \
		--top-module ysyx_25080230 \
		--prefix $(VERILATOR_PREFIX) \
		-f .slang/riscv_core.f

check: lint test verilator
