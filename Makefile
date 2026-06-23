# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

.PHONY: all test test-common-fifo test-if-stage test-id-stage test-ex-stage test-mem-stage test-wb-stage test-riscv-core wave wave-if-stage wave-id-stage wave-ex-stage wave-mem-stage wave-wb-stage wave-riscv-core wave-vcd wave-if-stage-vcd wave-id-stage-vcd wave-ex-stage-vcd wave-mem-stage-vcd wave-wb-stage-vcd wave-riscv-core-vcd lint lint-if-stage clean clean-build

all: test

test: test-common-fifo test-if-stage test-id-stage test-ex-stage test-mem-stage test-wb-stage test-riscv-core

test-common-fifo:
	$(MAKE) -C tests/cocotb/common_fifo test

wave: wave-if-stage wave-id-stage wave-ex-stage wave-mem-stage wave-wb-stage wave-riscv-core

wave-vcd: wave-if-stage-vcd wave-id-stage-vcd wave-ex-stage-vcd wave-mem-stage-vcd wave-wb-stage-vcd wave-riscv-core-vcd

test-if-stage:
	$(MAKE) -C tests/cocotb/if_stage test

test-id-stage:
	$(MAKE) -C tests/cocotb/id_stage test

test-ex-stage:
	$(MAKE) -C tests/cocotb/ex_stage test

test-mem-stage:
	$(MAKE) -C tests/cocotb/mem_stage test

test-wb-stage:
	$(MAKE) -C tests/cocotb/wb_stage test

test-riscv-core:
	$(MAKE) -C tests/cocotb/riscv_core test

wave-if-stage:
	$(MAKE) -C tests/cocotb/if_stage wave

wave-id-stage:
	$(MAKE) -C tests/cocotb/id_stage wave

wave-ex-stage:
	$(MAKE) -C tests/cocotb/ex_stage wave

wave-mem-stage:
	$(MAKE) -C tests/cocotb/mem_stage wave

wave-wb-stage:
	$(MAKE) -C tests/cocotb/wb_stage wave

wave-riscv-core:
	$(MAKE) -C tests/cocotb/riscv_core wave

wave-if-stage-vcd:
	$(MAKE) -C tests/cocotb/if_stage wave-vcd

wave-id-stage-vcd:
	$(MAKE) -C tests/cocotb/id_stage wave-vcd

wave-ex-stage-vcd:
	$(MAKE) -C tests/cocotb/ex_stage wave-vcd

wave-mem-stage-vcd:
	$(MAKE) -C tests/cocotb/mem_stage wave-vcd

wave-wb-stage-vcd:
	$(MAKE) -C tests/cocotb/wb_stage wave-vcd

wave-riscv-core-vcd:
	$(MAKE) -C tests/cocotb/riscv_core wave-vcd

clean: 
	rm -rf build
