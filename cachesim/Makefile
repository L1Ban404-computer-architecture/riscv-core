# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# 产物都落在 build/：可执行文件、目标文件、指令轨迹和仿真报告。
.DELETE_ON_ERROR:
CXX ?= g++
PYTHON ?= python3
BUILD_DIR ?= build
OUT_DIR := $(BUILD_DIR)
OBJ_DIR := $(BUILD_DIR)/obj
TARGET := $(OUT_DIR)/cachesim
RUNNER_TRACE := $(OUT_DIR)/runner-insttrace.bin
TRACE ?= $(RUNNER_TRACE)
SIM_REPORT := $(OUT_DIR)/sim.log

YSYX_HOME ?= $(abspath ../..)
AM_HOME ?= $(YSYX_HOME)/abstract-machine
MICROBENCH_DIR := $(YSYX_HOME)/am-kernels/benchmarks/microbench
ARCH ?= runner
DUT ?= nemu
MAINARGS ?= train

SETS ?= 4
WAYS ?= 2
BLOCK_BYTES ?= 16
POLICY ?= rr

SRCS := src/cache.cpp src/trace_reader.cpp src/main.cpp
OBJS := $(SRCS:%.cpp=$(OBJ_DIR)/%.o)
DEPS := $(OBJS:.o=.d)

CXXFLAGS ?= -O2 -g
CACHESIM_CPPFLAGS := -Iinclude -I$(YSYX_HOME)/riscv-runner/api/include
CACHESIM_CXXFLAGS := -std=c++17 -Wall -Wextra -Werror -MMD -MP

export AM_HOME

.DEFAULT_GOAL := cachesim

cachesim: $(TARGET)

# 轨迹缺失时先采集，再回放指定的 cache 几何。
sim: $(TARGET) $(TRACE)
	"$(TARGET)" --trace "$(TRACE)" --sets $(SETS) --ways $(WAYS) \
	  --block-bytes $(BLOCK_BYTES) --policy $(POLICY) > "$(SIM_REPORT)"
	@cat "$(SIM_REPORT)"

# 对同一条轨迹批量扫 cache 几何，报告写入 OUT_DIR。
run: $(TARGET) $(TRACE)
	$(PYTHON) -m dse --cachesim "$(abspath $(TARGET))" \
	  --trace "$(abspath $(TRACE))" --build-dir "$(abspath $(BUILD_DIR))"

$(TARGET): $(OBJS)
	@echo + LD $@
	@if [ -e $(OUT_DIR) ] && [ ! -d $(OUT_DIR) ]; then rm -f $(OUT_DIR); fi
	@mkdir -p $(OUT_DIR)
	$(CXX) -o $@ $(OBJS) $(LDFLAGS) $(LDLIBS)

$(OBJ_DIR)/%.o: %.cpp
	@echo + CXX $<
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(CACHESIM_CPPFLAGS) $(CACHESIM_CXXFLAGS) -c -o $@ $<

# 在 microbench 目录里 make run，DUT=nemu，默认 mainargs=train。
$(TRACE):
	@echo + INSTTRACE $@
	@if [ -e $(OUT_DIR) ] && [ ! -d $(OUT_DIR) ]; then rm -f $(OUT_DIR); fi
	@mkdir -p "$(OUT_DIR)"
	$(MAKE) -C "$(MICROBENCH_DIR)" ARCH=$(ARCH) DUT=$(DUT) mainargs=$(MAINARGS) \
	  LOG_DIR="$(abspath $(OUT_DIR))" INSTTRACE=1 run
	@if [ "$(abspath $(TRACE))" != "$(abspath $(RUNNER_TRACE))" ]; then \
	  mkdir -p "$(dir $(TRACE))"; \
	  mv "$(RUNNER_TRACE)" "$(TRACE)"; \
	fi

clean:
	-rm -rf $(BUILD_DIR)

-include $(DEPS)

.PHONY: cachesim sim run clean
