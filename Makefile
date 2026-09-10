# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# 工具、输出目录及全局告警配置；变量均可由命令行覆盖，便于接入不同环境。
VERILATOR ?= verilator
YOSYS ?= yosys
YOSYS_STA_HOME ?= $(HOME)/.local/yosys-sta
DESIGN ?= ysyx_25080230
CLK_PORT_NAME ?= clock
CLK_FREQ_MHZ ?= 5000
VERILATOR_BUILD_DIR ?= build/verilator
VERILATOR_PREFIX ?= core
VERILATOR_WARNINGS := -Wno-PINCONNECTEMPTY -Wno-IMPORTSTAR
ICACHE_WARNINGS := $(VERILATOR_WARNINGS) -Wno-TIMESCALEMOD -Wno-WIDTHTRUNC
SIM_WARNINGS := $(VERILATOR_WARNINGS) -Wno-UNUSEDPARAM

# 对外目标分为顶层检查和 I-cache 参数化 lint 入口。
.PHONY: lint verilator sim-lint sim-parameter-lint sim-verilator yosys-slang-core yosys-slang check icache-lint
.PHONY: perf

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

# 仿真专用核心顶层。DPI-C 函数由上层仿真环境提供实现。
sim-lint: sim-parameter-lint
	$(VERILATOR) --lint-only --sv --Wall $(SIM_WARNINGS) \
		-f .slang/riscv_core_sim.f

sim-parameter-lint:
	$(VERILATOR) --lint-only --sv --Wall $(SIM_WARNINGS) \
		-GImemResponseLatency=1 -GImemMaxOutstanding=2 \
		-GDmemResponseLatency=3 -GDmemMaxOutstanding=4 \
		-f .slang/riscv_core_sim.f

sim-verilator:
	$(VERILATOR) --cc --sv $(VERILATOR_WARNINGS) \
		--Mdir build/verilator-sim \
		--top-module riscv_core_sim \
		--prefix core_sim \
		-f .slang/riscv_core_sim.f

check: lint verilator yosys-slang

# I-cache 参数化配置的独立编译入口。
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

# 通过 slang 前端展开顶层，覆盖综合语义检查。
yosys-slang-core:
	$(YOSYS) -p 'plugin -i slang; read_slang --single-unit -f .slang/riscv_core.f'

yosys-slang: yosys-slang-core

# slang 只降低 SystemVerilog；工艺映射与 STA 交给上游 yosys-sta。
perf:
	@test -f "$(YOSYS_STA_HOME)/Makefile" && test -x "$(YOSYS_STA_HOME)/bin/iEDA" || \
		{ echo '请先安装 yosys-sta，并设置 YOSYS_STA_HOME（见 README.md）。' >&2; exit 1; }
	mkdir -p build/perf
	$(YOSYS) -Q -T -p 'plugin -i slang; read_slang --single-unit --ignore-assertions -f .slang/riscv_core.f; proc; bwmuxmap; write_verilog build/perf/rtl.v'
	$(MAKE) -B -C "$(YOSYS_STA_HOME)" sta \
		DESIGN="$(DESIGN)" CLK_PORT_NAME="$(CLK_PORT_NAME)" CLK_FREQ_MHZ="$(CLK_FREQ_MHZ)" \
		RTL_FILES="$(abspath build/perf/rtl.v)" O="$(abspath build/perf)"
