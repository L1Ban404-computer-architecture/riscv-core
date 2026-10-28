# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

.DEFAULT_GOAL := branchsim
.DELETE_ON_ERROR:
CXX ?= g++
PYTHON ?= python3
BUILD_DIR ?= build
TARGET := $(BUILD_DIR)/branchsim
MODEL_TEST := $(BUILD_DIR)/check-model
OBJ_DIR := $(BUILD_DIR)/obj
RUNNER_TRACE := $(BUILD_DIR)/runner-insttrace.bin
TRACE ?= $(RUNNER_TRACE)
SIM_REPORT := $(BUILD_DIR)/sim.log
DSE_ARGS ?=

YSYX_HOME ?= $(abspath ../..)
AM_HOME ?= $(YSYX_HOME)/abstract-machine
MICROBENCH_DIR := $(YSYX_HOME)/am-kernels/benchmarks/microbench
ARCH ?= runner
DUT ?= nemu
MAINARGS ?= train
export AM_HOME

BHT ?= btfn
BHT_ENTRIES ?= 32
BTB ?= table
BTB_SETS ?= 64
BTB_WAYS ?= 2
BTB_POLICY ?= rr
PC_BITS ?= 8
TARGET_BITS ?= 16

SRCS := $(sort $(wildcard src/*.cpp))
OBJS := $(SRCS:%.cpp=$(OBJ_DIR)/%.o)
DEPS := $(OBJS:.o=.d)
CXXFLAGS ?= -O2 -g
BRANCHSIM_CPPFLAGS := -Iinclude -I$(YSYX_HOME)/riscv-runner/api/include
BRANCHSIM_CXXFLAGS := -std=c++17 -Wall -Wextra -Werror -MMD -MP
SIM_ARGS = --trace "$(TRACE)" --bht "$(BHT)" --bht-entries "$(BHT_ENTRIES)" --btb "$(BTB)" \
  --btb-sets "$(BTB_SETS)" --btb-ways "$(BTB_WAYS)" --btb-policy "$(BTB_POLICY)" \
  --pc-bits "$(PC_BITS)" --target-bits "$(TARGET_BITS)"

branchsim: $(TARGET)

# sim 只回放；run 则允许在轨迹缺失时先采集。
sim: $(TARGET)
	@test -f "$(TRACE)" || { echo "missing $(TRACE); build it with: make run" >&2; exit 1; }
	@$(TARGET) $(SIM_ARGS) > "$(SIM_REPORT).tmp" && mv "$(SIM_REPORT).tmp" "$(SIM_REPORT)"
	@cat "$(SIM_REPORT)"

run: $(TARGET) $(TRACE)
	$(PYTHON) -m dse --branchsim "$(abspath $(TARGET))" \
	  --trace "$(abspath $(TRACE))" --build-dir "$(abspath $(BUILD_DIR))" $(DSE_ARGS)

check-dse: $(TARGET)
	BRANCHSIM="$(abspath $(TARGET))" $(PYTHON) -m unittest dse.test_dse

check-model: $(MODEL_TEST) $(TARGET)
	$(MODEL_TEST)
	$(PYTHON) tests/check_alias_trace.py "$(abspath $(TARGET))"

$(MODEL_TEST): tests/model.cpp src/btb.cpp src/bht.cpp src/predictor.cpp $(wildcard include/*.hpp)
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(BRANCHSIM_CPPFLAGS) -std=c++17 -Wall -Wextra -Werror \
	  -o $@ tests/model.cpp src/btb.cpp src/bht.cpp src/predictor.cpp $(LDFLAGS) $(LDLIBS)

$(TRACE):
	@mkdir -p "$(BUILD_DIR)"
	$(MAKE) -C "$(MICROBENCH_DIR)" ARCH=$(ARCH) DUT=$(DUT) mainargs=$(MAINARGS) \
	  LOG_DIR="$(abspath $(BUILD_DIR))" INSTTRACE=1 run
	@if [ "$(abspath $(TRACE))" != "$(abspath $(RUNNER_TRACE))" ]; then \
	  mkdir -p "$(dir $(TRACE))"; \
	  mv "$(RUNNER_TRACE)" "$(TRACE)"; \
	fi

$(TARGET): $(OBJS)
	@echo + LD $@
	@mkdir -p $(dir $@)
	$(CXX) -o $@ $(OBJS) $(LDFLAGS) $(LDLIBS)

$(OBJ_DIR)/%.o: %.cpp
	@echo + CXX $<
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(BRANCHSIM_CPPFLAGS) $(BRANCHSIM_CXXFLAGS) -c -o $@ $<

clean:
	-rm -rf $(BUILD_DIR)

-include $(DEPS)
.PHONY: branchsim sim run check-model check-dse clean
