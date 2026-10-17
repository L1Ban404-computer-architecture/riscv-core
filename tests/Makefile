# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

VERILATOR ?= verilator
RVE ?= 1
BUILD_DIR := ../build/forwarding-rve$(RVE)
SOURCES := ../rtl/core/riscv_core_pkg.sv ../rtl/core/riscv_core_if.sv \
	../rtl/core/units/forwarding_unit.sv
TESTS := stream_register_tb stream_fifo_tb forwarding_tb forwarding_pipeline_tb pipeline_flush_tb if_stage_tb mem_stage_tb

.PHONY: test $(TESTS)
test: $(TESTS)

stream_register_tb: EXTRA_SOURCES := ../rtl/common/stream_register.sv
stream_fifo_tb: EXTRA_SOURCES := ../rtl/common/stream_fifo.sv ../rtl/common/fall_through_register.sv
forwarding_tb: EXTRA_SOURCES :=
forwarding_pipeline_tb: EXTRA_SOURCES := ../rtl/core/units/regfile.sv \
	../rtl/common/stream_fifo.sv ../rtl/common/stream_register.sv
pipeline_flush_tb: EXTRA_SOURCES := ../rtl/bus/riscv_bus_pkg.sv \
	../rtl/bus/riscv_bus_if.sv ../rtl/core/riscv_debug_pkg.sv ../rtl/common/stream_fifo.sv \
	../rtl/common/stream_register.sv ../rtl/common/fall_through_register.sv \
	../rtl/core/pipeline/id_stage.sv ../rtl/core/pipeline/ex_stage.sv \
	../rtl/core/pipeline/wb_stage.sv ../rtl/core/pipeline/mem_stage.sv ../rtl/core/pipeline/pipeline_ctrl.sv \
	-y ../rtl/core/units
if_stage_tb: EXTRA_SOURCES := ../rtl/bus/riscv_bus_pkg.sv ../rtl/core/riscv_debug_pkg.sv \
	../rtl/bus/riscv_bus_if.sv ../rtl/core/riscv_debug_if.sv \
	../rtl/common/stream_fifo.sv ../rtl/common/stream_register.sv \
	../rtl/common/fall_through_register.sv ../rtl/core/pipeline/if_stage.sv \
	../rtl/core/pipeline/retire_debug.sv ../rtl/core/pipeline/retire_inflight_queue.sv
mem_stage_tb: EXTRA_SOURCES := ../rtl/bus/riscv_bus_pkg.sv ../rtl/core/riscv_debug_pkg.sv \
	../rtl/bus/riscv_bus_if.sv ../rtl/common/stream_register.sv \
	../rtl/core/pipeline/mem_stage.sv -y ../rtl/core/units

$(TESTS):
	$(VERILATOR) --binary --timing --assert -DRISCV_CORE_RVE=$(RVE) \
		--top-module $@ --Mdir $(BUILD_DIR)/$@ $(SOURCES) $(EXTRA_SOURCES) $@.sv
	$(BUILD_DIR)/$@/V$@
