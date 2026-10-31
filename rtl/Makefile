# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

SHELL := /bin/bash
.DEFAULT_GOAL := check
CORE_DIR := $(abspath ..)

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
CLK_FREQ_MHZ ?= 1000
export CLK_PORT_NAME CLK_FREQ_MHZ
PDK ?= nangate45
# 综合产物统一放在项目根 build/；离线扫描为每个点传入独立路径。
PERF_OUT ?= $(CORE_DIR)/build/rtl/perf
# 顶层参数覆盖，原样交给 read_slang。例如 -GSetCount=8 -GWayCount=2。
# ReplacementPolicy 要写 icache_pkg 的枚举名，整数不能隐式转成该枚举。
SLANG_PARAMS ?=

PERF_DIR := $(abspath $(PERF_OUT))/$(TOP)-$(CLK_FREQ_MHZ)MHz
PERF_NETLIST := $(PERF_DIR)/$(TOP).netlist.v

.PHONY: check perf

# 本目录下全部 SystemVerilog；生成文件位于项目根 build/，不参与源文件搜索。
HDL_SRCS := $(shell find . -type f \( -name '*.sv' -o -name '*.svh' \) -print | LC_ALL=C sort)
ifeq ($(strip $(HDL_SRCS)),)
$(error 未找到 SystemVerilog 源文件)
endif

# 通过 slang 前端展开顶层，覆盖综合语义检查。
SLANG_FLAGS := $(ISA_FLAGS) -D SYNTHESIS --single-unit --top $(TOP)

check:
	$(YOSYS) -p 'plugin -i slang; read_slang $(SLANG_FLAGS) $(HDL_SRCS)'

# slang 与工艺映射在同一 Yosys 进程中执行，避免导出 Verilog 后重新解析。
# 上游映射脚本传入空源文件列表，直接使用当前进程已加载的设计。
# 面积预算按讲义使用 nangate45；可覆盖 PDK=icsprout55 做对照。
perf:
	mkdir -p "$(PERF_DIR)"
	$(YOSYS) -Q -l "$(PERF_DIR)/yosys.log" -p 'plugin -i slang; read_slang $(SLANG_FLAGS) $(SLANG_PARAMS) --ignore-assertions $(HDL_SRCS); proc; bwmuxmap; tcl $(YOSYS_STA_HOME)/scripts/yosys.tcl $(TOP) $(PDK) "" $(PERF_NETLIST)'
	set -o pipefail; "$(YOSYS_STA_HOME)/bin/iEDA" -script \
		"$(YOSYS_STA_HOME)/scripts/sta.tcl" "$(YOSYS_STA_HOME)/scripts/default.sdc" \
		"$(PERF_NETLIST)" $(TOP) $(PDK) 2>&1 | tee "$(PERF_DIR)/sta.log"
