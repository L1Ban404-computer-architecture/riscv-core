# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

VERILATOR ?= verilator
YOSYS ?= yosys
VERILATOR_BUILD_DIR ?= build/verilator
VERILATOR_PREFIX ?= core
VERILATOR_WARNINGS := -Wno-PINCONNECTEMPTY -Wno-IMPORTSTAR \
	-Wno-SYNCASYNCNET -Wno-UNOPTFLAT
CACHE_DEV_BUILD_DIR ?= build/cache_dev_tb
CACHE_DEV_WARNINGS := $(VERILATOR_WARNINGS) -Wno-TIMESCALEMOD

.PHONY: lint verilator yosys-slang-core yosys-slang-cache yosys-slang check \
	cache-dev-lint cache-dev-test \
	cache-dev-test-default cache-dev-test-readonly \
	cache-dev-test-minimum cache-dev-test-direct cache-dev-test-four-way \
	cache-dev-test-latency

lint:
	$(VERILATOR) --lint-only --sv --Wall $(VERILATOR_WARNINGS) \
		-f .slang/riscv_core.f

verilator:
	$(VERILATOR) --cc --build --sv $(VERILATOR_WARNINGS) \
		--Mdir $(VERILATOR_BUILD_DIR) \
		--top-module ysyx_25080230 \
		--prefix $(VERILATOR_PREFIX) \
		-f .slang/riscv_core.f

check: lint verilator yosys-slang

yosys-slang-core:
	$(YOSYS) -p 'plugin -i slang; read_slang --single-unit -f .slang/riscv_core.f'

yosys-slang-cache:
	$(YOSYS) -p 'plugin -i slang; read_slang --single-unit -f .slang/cache_dev.f'

yosys-slang: yosys-slang-core yosys-slang-cache

cache-dev-lint:
	$(VERILATOR) --lint-only --sv --Wall $(VERILATOR_WARNINGS) \
		-f rtl/cache_dev/cache_dev.f
	$(VERILATOR) --lint-only --sv --Wall $(VERILATOR_WARNINGS) \
		-GReadOnly=1 -GAxiId=0 -f rtl/cache_dev/cache_dev.f
	$(VERILATOR) --lint-only --sv --Wall $(VERILATOR_WARNINGS) \
		-GReadOnly=1 -GBlockBytes=4 -GSetCount=1 -GWayCount=1 \
		-GLookupLatency=1 -GMaxOutstanding=1 -GAxiId=0 \
		-f rtl/cache_dev/cache_dev.f
	$(VERILATOR) --lint-only --sv --Wall $(VERILATOR_WARNINGS) \
		-GWayCount=4 -f rtl/cache_dev/cache_dev.f
	$(VERILATOR) --lint-only --sv --Wall $(VERILATOR_WARNINGS) \
		-GLookupLatency=2 -GMaxOutstanding=3 -f rtl/cache_dev/cache_dev.f

cache-dev-test: cache-dev-test-default cache-dev-test-readonly \
	cache-dev-test-minimum cache-dev-test-direct cache-dev-test-four-way \
	cache-dev-test-latency

cache-dev-test-default:
	mkdir -p $(CACHE_DEV_BUILD_DIR)/default
	+$(VERILATOR) --binary --timing --sv --Wall $(CACHE_DEV_WARNINGS) \
		--Mdir $(CACHE_DEV_BUILD_DIR)/default -o cache_dev_tb \
		-f rtl/cache_dev/cache_dev_tb.f
	$(CACHE_DEV_BUILD_DIR)/default/cache_dev_tb

cache-dev-test-readonly:
	mkdir -p $(CACHE_DEV_BUILD_DIR)/readonly
	+$(VERILATOR) --binary --timing --sv --Wall $(CACHE_DEV_WARNINGS) \
		--Mdir $(CACHE_DEV_BUILD_DIR)/readonly -o cache_dev_tb \
		-GReadOnly=1 -GAxiId=0 -f rtl/cache_dev/cache_dev_tb.f
	$(CACHE_DEV_BUILD_DIR)/readonly/cache_dev_tb

cache-dev-test-minimum:
	mkdir -p $(CACHE_DEV_BUILD_DIR)/minimum
	+$(VERILATOR) --binary --timing --sv --Wall $(CACHE_DEV_WARNINGS) \
		--Mdir $(CACHE_DEV_BUILD_DIR)/minimum -o cache_dev_tb \
		-GBlockBytes=4 -GSetCount=1 -GWayCount=1 -GMaxOutstanding=1 \
		-f rtl/cache_dev/cache_dev_tb.f
	$(CACHE_DEV_BUILD_DIR)/minimum/cache_dev_tb

cache-dev-test-direct:
	mkdir -p $(CACHE_DEV_BUILD_DIR)/direct
	+$(VERILATOR) --binary --timing --sv --Wall $(CACHE_DEV_WARNINGS) \
		--Mdir $(CACHE_DEV_BUILD_DIR)/direct -o cache_dev_tb \
		-GWayCount=1 -f rtl/cache_dev/cache_dev_tb.f
	$(CACHE_DEV_BUILD_DIR)/direct/cache_dev_tb

cache-dev-test-four-way:
	mkdir -p $(CACHE_DEV_BUILD_DIR)/four_way
	+$(VERILATOR) --binary --timing --sv --Wall $(CACHE_DEV_WARNINGS) \
		--Mdir $(CACHE_DEV_BUILD_DIR)/four_way -o cache_dev_tb \
		-GWayCount=4 -f rtl/cache_dev/cache_dev_tb.f
	$(CACHE_DEV_BUILD_DIR)/four_way/cache_dev_tb

cache-dev-test-latency:
	mkdir -p $(CACHE_DEV_BUILD_DIR)/latency
	+$(VERILATOR) --binary --timing --sv --Wall $(CACHE_DEV_WARNINGS) \
		--Mdir $(CACHE_DEV_BUILD_DIR)/latency -o cache_dev_tb \
		-GLookupLatency=2 -GMaxOutstanding=3 \
		-f rtl/cache_dev/cache_dev_tb.f
	$(CACHE_DEV_BUILD_DIR)/latency/cache_dev_tb
