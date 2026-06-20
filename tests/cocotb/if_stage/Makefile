SIM ?= verilator
TOPLEVEL_LANG ?= verilog

REPO_ROOT := $(abspath ../../..)

TOPLEVEL := if_stage_tb
MODULE := test_if_stage
FETCH_OUTSTANDING_DEPTH ?= 4
IF_ID_QUEUE_DEPTH ?= 2

VERILOG_SOURCES := \
  $(REPO_ROOT)/rtl/include/riscv_core_pkg.sv \
  $(REPO_ROOT)/third_party/ip/common_cells/src/fifo_v3.sv \
  $(REPO_ROOT)/third_party/ip/common_cells/src/stream_fifo.sv \
  $(REPO_ROOT)/third_party/ip/common_cells/src/fall_through_register.sv \
  $(REPO_ROOT)/rtl/core/pipe/if_stage.sv \
  $(REPO_ROOT)/tests/cocotb/if_stage/if_stage_tb.sv

COMPILE_ARGS += -I$(REPO_ROOT)/third_party/ip/common_cells/include
COMPILE_ARGS += -Wno-PINCONNECTEMPTY
COMPILE_ARGS += -Wno-IMPORTSTAR
COMPILE_ARGS += -Wno-UNUSEDPARAM
COMPILE_ARGS += -Wno-SYNCASYNCNET
COMPILE_ARGS += -Wno-UNOPTFLAT

EXTRA_ARGS += --top-module $(TOPLEVEL)
EXTRA_ARGS += -GFetchOutstandingDepth=$(FETCH_OUTSTANDING_DEPTH)
EXTRA_ARGS += -GIfIdQueueDepth=$(IF_ID_QUEUE_DEPTH)

include $(shell cocotb-config --makefiles)/Makefile.sim
