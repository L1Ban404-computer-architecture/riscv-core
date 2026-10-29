# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0
.DEFAULT_GOAL := check
ROOT := $(abspath ../..)
BUILD := $(ROOT)/build/branch-predictor
VERILATOR ?= verilator
SETS ?= 1
WAYS ?= 4
BHT ?= 16
MODEL_DIR := $(BUILD)/model-s$(SETS)-w$(WAYS)-h$(BHT)
PKG := $(ROOT)/rtl/core/riscv_core_pkg.sv
IFACE := $(ROOT)/rtl/core/riscv_core_if.sv
PREDICTOR := $(ROOT)/rtl/core/units/branch_predictor.sv
CORE_SRCS := $(PKG) $(IFACE) $(PREDICTOR)
MODEL_SRCS := $(ROOT)/branchsim/src/btb.cpp $(ROOT)/branchsim/src/bht.cpp $(ROOT)/branchsim/src/predictor.cpp

.PHONY: check model pipeline
check:
	$(MAKE) model
	$(MAKE) model SETS=2 WAYS=2 BHT=8
	$(MAKE) pipeline

model:
	$(VERILATOR) --cc --exe --build -j 2 --assert -DSYNTHESIS --top-module branch_predictor_test_top \
	  --Mdir $(MODEL_DIR) -GSetCount=$(SETS) -GWayCount=$(WAYS) -GBhtEntries=$(BHT) \
	  -CFLAGS '-std=c++17 -I$(ROOT)/branchsim/include -DTEST_SETS=$(SETS) -DTEST_WAYS=$(WAYS) -DTEST_BHT=$(BHT)' \
	  $(CORE_SRCS) $(abspath top.sv model.cpp) $(MODEL_SRCS)
	$(MODEL_DIR)/Vbranch_predictor_test_top

pipeline:
	$(VERILATOR) --binary --timing --assert -DSYNTHESIS --top-module pipeline_tb \
	  --Mdir $(BUILD)/pipeline -j 2 \
	  $(ROOT)/rtl/bus/riscv_bus_pkg.sv $(PKG) $(ROOT)/rtl/bus/riscv_bus_if.sv $(IFACE) \
	  -y $(ROOT)/rtl/common -y $(ROOT)/rtl/core/units -y $(ROOT)/rtl/core/pipeline \
	  $(abspath pipeline_tb.sv)
	$(BUILD)/pipeline/Vpipeline_tb
