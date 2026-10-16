# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

VERILATOR ?= verilator
RVE ?= 1
BUILD_DIR := ../build/forwarding-rve$(RVE)
SOURCES := ../rtl/common/riscv_common_pkg.sv \
	../rtl/core/riscv_core_pkg.sv ../rtl/core/riscv_core_if.sv \
	../rtl/core/units/forwarding_unit.sv
TESTS := forwarding_tb forwarding_pipeline_tb

.PHONY: test $(TESTS)
test: $(TESTS)

forwarding_tb: EXTRA_SOURCES :=
forwarding_pipeline_tb: EXTRA_SOURCES := ../rtl/core/units/regfile.sv \
	../rtl/common/stream_fifo.sv ../rtl/common/stream_register.sv

$(TESTS):
	$(VERILATOR) --binary --timing --assert -DRISCV_CORE_RVE=$(RVE) \
		--top-module $@ --Mdir $(BUILD_DIR)/$@ $(SOURCES) $(EXTRA_SOURCES) $@.sv
	$(BUILD_DIR)/$@/V$@
