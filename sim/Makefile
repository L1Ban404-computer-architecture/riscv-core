.DEFAULT_GOAL := run
.DELETE_ON_ERROR:

CORE_DIR := $(abspath ..)
YSYX_HOME ?= $(abspath ../..)
MODEL ?= branch
ifeq ($(filter $(MODEL),branch icache),)
$(error MODEL must be branch or icache)
endif

BUILD_DIR := $(CORE_DIR)/build/sim
TARGET := $(BUILD_DIR)/$(MODEL)/$(MODEL)
CONFIG ?= $(MODEL)/config.json
RESULT ?= $(BUILD_DIR)/$(MODEL)/result.json
TRACE ?= $(BUILD_DIR)/shared/runner-insttrace.bin
SCAN_DIR ?= $(BUILD_DIR)/$(MODEL)/scan
SCAN_ARGS ?=
JOBS ?= 16
PYTHON ?= python3
export PYTHONPATH := $(CORE_DIR)
export PYTHONDONTWRITEBYTECODE := 1

CXXFLAGS ?= -O2 -g
SIM_CPPFLAGS := -I$(MODEL)/include -Icommon -I$(YSYX_HOME)/riscv-runner/api/include \
                -DSIM_CORE_DIR='"$(CORE_DIR)"'
SIM_CXXFLAGS := -std=c++17 -Wall -Wextra -Werror -MMD -MP
SOURCES := $(wildcard $(MODEL)/src/*.cpp common/*.cpp)
OBJECTS := $(SOURCES:%.cpp=$(BUILD_DIR)/obj/%.o)

# 按默认配置执行一次；缺失轨迹由 C++ 自动采集 microbench train。
run: $(TARGET)
	$(TARGET) "$(CONFIG)" "$(RESULT)"

# 一次完成参数生成、仿真和绘图。
scan: $(TARGET)
	$(PYTHON) -m sim.$(MODEL).generate --trace "$(TRACE)" \
	  --simulator "$(TARGET)" --out "$(SCAN_DIR)" $(SCAN_ARGS)
	$(PYTHON) -m sim.common.run "$(SCAN_DIR)/scan.json" --jobs $(JOBS)
	$(PYTHON) -m sim.common.plot "$(SCAN_DIR)/scan.json"

$(TARGET): $(OBJECTS)
	@mkdir -p $(dir $@)
	$(CXX) -o $@ $^ $(LDFLAGS) $(LDLIBS)

$(BUILD_DIR)/obj/%.o: %.cpp Makefile
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(SIM_CPPFLAGS) $(SIM_CXXFLAGS) -c -o $@ $<

-include $(OBJECTS:.o=.d)
.PHONY: run scan
