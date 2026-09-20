# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# 产物都落在 $(BUILD_DIR)/cachesim/：可执行文件、PC 轨迹和仿真报告。
CXX ?= g++
PYTHON ?= python3
BUILD_DIR ?= ../build
OUT_DIR := $(BUILD_DIR)/cachesim
OBJ_DIR := $(BUILD_DIR)/obj/cachesim
TARGET := $(OUT_DIR)/cachesim
PCTRACE := $(OUT_DIR)/microbench.pc
SIM_REPORT := $(OUT_DIR)/sim.log
DSE_REPORT := $(OUT_DIR)/dse.csv

YSYX_HOME ?= $(abspath ../..)
AM_HOME ?= $(YSYX_HOME)/abstract-machine
MICROBENCH_DIR := $(YSYX_HOME)/am-kernels/benchmarks/microbench
ARCH ?= runner
DUT ?= nemu
MAINARGS ?= train

SETS ?= 16
WAYS ?= 1
BLOCK_BYTES ?= 4
POLICY ?= rr

SRCS := src/cache.cpp src/trace.cpp src/main.cpp
OBJS := $(SRCS:%.cpp=$(OBJ_DIR)/%.o)
DEPS := $(OBJS:.o=.d)

CXXFLAGS ?= -O2 -g
CACHESIM_CPPFLAGS := -Iinclude
CACHESIM_CXXFLAGS := -std=c++17 -Wall -Wextra -Werror -MMD -MP
DSE_SCRIPT := scripts/dse.py

export AM_HOME

.DEFAULT_GOAL := cachesim

cachesim: $(TARGET)
pctrace: $(PCTRACE)

# 轨迹已存在时只跑 cachesim；缺失时请先构建 $(PCTRACE)。
sim: $(TARGET) $(PCTRACE)
	@test -f $(PCTRACE) || { \
	  echo "missing $(PCTRACE); build it with: make $(PCTRACE)" >&2; \
	  exit 1; \
	}
	$(TARGET) --trace $(PCTRACE) --sets $(SETS) --ways $(WAYS) \
	  --block-bytes $(BLOCK_BYTES) --policy $(POLICY) > $(SIM_REPORT)
	@cat $(SIM_REPORT)

# 对同一条轨迹批量扫 cache 几何，报告写入 OUT_DIR。
run: $(TARGET) $(PCTRACE)
	@test -f $(PCTRACE) || { \
	  echo "missing $(PCTRACE); build it with: make $(PCTRACE)" >&2; \
	  exit 1; \
	}
	$(PYTHON) $(DSE_SCRIPT) --trace $(PCTRACE) --cachesim $(TARGET) \
	  --output $(DSE_REPORT)

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
$(PCTRACE):
	@echo + PCTRACE $@
	@if [ -e $(OUT_DIR) ] && [ ! -d $(OUT_DIR) ]; then rm -f $(OUT_DIR); fi
	@mkdir -p $(OUT_DIR)
	$(MAKE) -C $(MICROBENCH_DIR) ARCH=$(ARCH) DUT=$(DUT) mainargs=$(MAINARGS) \
	  PCTRACE="$(abspath $@)" run

clean:
	-rm -rf $(OUT_DIR) $(OBJ_DIR)
	-rm -f $(BUILD_DIR)/cachesim

-include $(DEPS)

.PHONY: cachesim pctrace sim run clean
