# Standalone builds default to RV32E; SoC builds derive this from the contract.
RVE ?= 1
ifeq ($(filter $(RVE),0 1),)
$(error RVE must be 0 or 1)
endif
export RVE
ISA_FLAGS := -DRISCV_CORE_RVE=$(RVE)

# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# 工具与综合参数；变量均可由命令行覆盖，便于接入不同环境。
YOSYS ?= yosys
YOSYS_STA_HOME ?= $(HOME)/.local/yosys-sta
# 综合顶层。文件列表不写 --top；可改为 icache_top 或 riscv_core_sim。
TOP ?= ysyx_25080230
# SoC 顶层时钟叫 clock，其余模块遵循 clk_i。命令行传入的值优先。
ifeq ($(TOP),ysyx_25080230)
CLK_PORT_NAME ?= clock
else
CLK_PORT_NAME ?= clk_i
endif
CLK_FREQ_MHZ ?= 5000
PDK ?= nangate45

# 综合语义检查与面积/时序分析。仿真模型由 mini-soc、ysyx-soc 自行 Verilate。
SBY ?= sby

.PHONY: check perf formal-icache

# 通过 slang 前端展开顶层，覆盖综合语义检查。
check:
	$(YOSYS) -p 'plugin -i slang; read_slang $(ISA_FLAGS) -D SYNTHESIS --single-unit --top $(TOP) -f .slang/riscv_core.f'

# slang 只降低 SystemVerilog；工艺映射与 STA 交给上游 yosys-sta。
# 面积预算按讲义使用 nangate45；可覆盖 PDK=icsprout55 做对照。
perf:
	mkdir -p build/perf
	$(YOSYS) -Q -T -p 'plugin -i slang; read_slang $(ISA_FLAGS) -D SYNTHESIS --single-unit --ignore-assertions --top $(TOP) -f .slang/riscv_core.f; proc; bwmuxmap; write_verilog build/perf/rtl.v'
	$(MAKE) -B -C "$(YOSYS_STA_HOME)" sta \
		DESIGN="$(TOP)" CLK_PORT_NAME="$(CLK_PORT_NAME)" CLK_FREQ_MHZ="$(CLK_FREQ_MHZ)" \
		PDK="$(PDK)" RTL_FILES="$(abspath build/perf/rtl.v)" O="$(abspath build/perf)"

# I-cache 取指一致性：复位后 20 拍的有界检查。工作目录在 build/，可重复运行。
formal-icache:
	mkdir -p build/formal
	$(SBY) -f --prefix build/formal/icache_fetch formal/icache/icache_fetch.sby
