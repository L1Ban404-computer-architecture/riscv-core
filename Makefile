# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# 工具、输出目录及全局告警配置；变量均可由命令行覆盖，便于接入不同环境。
VERILATOR ?= verilator
YOSYS ?= yosys
VERILATOR_BUILD_DIR ?= build/verilator
VERILATOR_PREFIX ?= core
VERILATOR_WARNINGS := -Wno-PINCONNECTEMPTY -Wno-IMPORTSTAR \
	-Wno-SYNCASYNCNET -Wno-UNOPTFLAT
CACHE_DEV_WARNINGS := $(VERILATOR_WARNINGS) -Wno-TIMESCALEMOD
ICACHE_WARNINGS := $(CACHE_DEV_WARNINGS) -Wno-WIDTHTRUNC

# 对外目标分为核心检查、通用 cache lint 与超小型 I-cache lint 入口。
.PHONY: lint verilator yosys-slang-core yosys-slang-cache yosys-slang \
	check cache-dev-lint icache-lint

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

check: lint verilator yosys-slang

# 超小型 I-cache 保持独立编译，避免与 rtl/cache/ 下的旧同名模块同时载入。
icache-lint:
	$(VERILATOR) --lint-only --sv --Wall $(ICACHE_WARNINGS) \
		-f rtl/icache/icache.f
	$(VERILATOR) --lint-only --sv --Wall $(ICACHE_WARNINGS) \
		-GBlockBytes=16 -GSetCount=1 -GWayCount=1 \
		-f rtl/icache/icache.f
	$(VERILATOR) --lint-only --sv --Wall $(ICACHE_WARNINGS) \
		-GReplacementPolicy=0 -f rtl/icache/icache.f
	$(VERILATOR) --lint-only --sv --Wall $(ICACHE_WARNINGS) \
		-GWayCount=4 -GReplacementPolicy=2 -f rtl/icache/icache.f

# 通过 slang 前端展开核心与 cache，覆盖综合语义检查。
yosys-slang-core:
	$(YOSYS) -p 'plugin -i slang; read_slang --single-unit -f .slang/riscv_core.f'

yosys-slang-cache:
	$(YOSYS) -p 'plugin -i slang; read_slang --single-unit -f .slang/cache_dev.f'

yosys-slang: yosys-slang-core yosys-slang-cache

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
