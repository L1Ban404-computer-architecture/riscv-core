# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

.PHONY: all test test-if-stage test-id-stage wave wave-if-stage wave-id-stage wave-vcd wave-if-stage-vcd wave-id-stage-vcd lint lint-if-stage clean clean-build

all: test

test: test-if-stage test-id-stage

wave: wave-if-stage wave-id-stage

wave-vcd: wave-if-stage-vcd wave-id-stage-vcd

test-if-stage:
	$(MAKE) -C tests/cocotb/if_stage test

test-id-stage:
	$(MAKE) -C tests/cocotb/id_stage test

wave-if-stage:
	$(MAKE) -C tests/cocotb/if_stage wave

wave-id-stage:
	$(MAKE) -C tests/cocotb/id_stage wave

wave-if-stage-vcd:
	$(MAKE) -C tests/cocotb/if_stage wave-vcd

wave-id-stage-vcd:
	$(MAKE) -C tests/cocotb/id_stage wave-vcd

clean: 
	rm -rf build
