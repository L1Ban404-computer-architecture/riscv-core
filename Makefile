# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# 工具、输出目录及全局告警配置；变量均可由命令行覆盖，便于接入不同环境。
VERILATOR ?= verilator
YOSYS ?= yosys
VERILATOR_BUILD_DIR ?= build/verilator
VERILATOR_PREFIX ?= core
VERILATOR_WARNINGS := -Wno-PINCONNECTEMPTY -Wno-IMPORTSTAR \
	-Wno-SYNCASYNCNET -Wno-UNOPTFLAT
CACHE_DEV_BUILD_DIR ?= build/cache_dev_tb
CACHE_DEV_WARNINGS := $(VERILATOR_WARNINGS) -Wno-TIMESCALEMOD
BUS_WIDTH_BUILD_DIR ?= build/bus_width_tb

# 对外目标分为核心检查、总线参数化检查和 cache 开发回归三组。
.PHONY: lint verilator yosys-slang-core yosys-slang-cache \
	yosys-slang-bus-width yosys-slang check bus-width-lint bus-width-test \
	cache-dev-lint cache-dev-test \
	cache-dev-test-default cache-dev-test-readonly \
	cache-dev-test-minimum cache-dev-test-direct cache-dev-test-four-way \
cache-dev-test-latency

# 核心 RTL 的静态检查、C++ 模型构建与聚合回归入口。
lint:
	$(VERILATOR) --lint-only --sv --Wall $(VERILATOR_WARNINGS) \
		-f .slang/riscv_core.f

verilator:
	$(VERILATOR) --cc --build --sv $(VERILATOR_WARNINGS) \
		--Mdir $(VERILATOR_BUILD_DIR) \
		--top-module ysyx_25080230 \
		--prefix $(VERILATOR_PREFIX) \
		-f .slang/riscv_core.f

check: lint verilator bus-width-lint bus-width-test yosys-slang

# 使用非默认总线宽度进行语法检查和自检仿真，防止参数被固定宽度截断。
bus-width-lint:
	$(VERILATOR) --lint-only --timing --sv --Wall $(CACHE_DEV_WARNINGS) \
		-f rtl/bus/bus_width_tb.f

bus-width-test:
	mkdir -p $(BUS_WIDTH_BUILD_DIR)
	+$(VERILATOR) --binary --timing --sv --Wall $(CACHE_DEV_WARNINGS) \
		--Mdir $(BUS_WIDTH_BUILD_DIR) -o bus_width_tb \
		-f rtl/bus/bus_width_tb.f
	$(BUS_WIDTH_BUILD_DIR)/bus_width_tb

# 通过 slang 前端分别展开核心、cache 和总线基础设施，覆盖综合语义检查。
yosys-slang-core:
	$(YOSYS) -p 'plugin -i slang; read_slang --single-unit -f .slang/riscv_core.f'

yosys-slang-cache:
	$(YOSYS) -p 'plugin -i slang; read_slang --single-unit -f .slang/cache_dev.f'

yosys-slang-bus-width:
	$(YOSYS) -p 'plugin -i slang; read_slang --single-unit -f .slang/bus_width.f'

yosys-slang: yosys-slang-core yosys-slang-cache yosys-slang-bus-width

# cache lint 覆盖只读、最小几何、四路组相联及多周期查询等关键参数组合。
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

# cache 自检回归与 lint 使用相同的代表性参数矩阵，每种配置使用独立构建目录。
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
