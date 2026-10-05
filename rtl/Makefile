# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# Standalone builds default to RV32E; SoC builds derive this from the contract.
RVE ?= 1
ifeq ($(filter $(RVE),0 1),)
$(error RVE must be 0 or 1)
endif
export RVE
ISA_FLAGS := -DRISCV_CORE_RVE=$(RVE)

# 工具与综合参数；变量均可由命令行覆盖，便于接入不同环境。
YOSYS ?= yosys
YOSYS_STA_HOME ?= $(HOME)/.local/yosys-sta
# 综合顶层。可改为 icache_top 或 riscv_core_sim。
TOP ?= ysyx_25080230
# SoC 顶层时钟叫 clock，其余模块遵循 clk_i。命令行传入的值优先。
ifeq ($(TOP),ysyx_25080230)
CLK_PORT_NAME ?= clock
else
CLK_PORT_NAME ?= clk_i
endif
CLK_FREQ_MHZ ?= 5000
PDK ?= nangate45

.PHONY: check perf clean

# 本目录下全部 SystemVerilog，排除 build/ 中的产物。新增子目录会被自动纳入。
HDL_SRCS := $(shell find . \( -path ./build -prune \) -o -type f \( -name '*.sv' -o -name '*.svh' \) -print | LC_ALL=C sort)
ifeq ($(strip $(HDL_SRCS)),)
$(error 未找到 SystemVerilog 源文件)
endif

# 通过 slang 前端展开顶层，覆盖综合语义检查。
SLANG_FLAGS := $(ISA_FLAGS) -D SYNTHESIS --single-unit --top $(TOP)

check:
	$(YOSYS) -p 'plugin -i slang; read_slang $(SLANG_FLAGS) $(HDL_SRCS)'

# slang 只降低 SystemVerilog；工艺映射与 STA 交给上游 yosys-sta。
# 面积预算按讲义使用 nangate45；可覆盖 PDK=icsprout55 做对照。
perf:
	mkdir -p build/perf
	$(YOSYS) -Q -T -p 'plugin -i slang; read_slang $(SLANG_FLAGS) --ignore-assertions $(HDL_SRCS); proc; bwmuxmap; write_verilog build/perf/rtl.v'
	$(MAKE) -B -C "$(YOSYS_STA_HOME)" sta \
		DESIGN="$(TOP)" CLK_PORT_NAME="$(CLK_PORT_NAME)" CLK_FREQ_MHZ="$(CLK_FREQ_MHZ)" \
		PDK="$(PDK)" RTL_FILES="$(abspath build/perf/rtl.v)" O="$(abspath build/perf)"

clean:
	rm -rf build
