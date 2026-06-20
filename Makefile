# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

.PHONY: all test test-if-stage wave wave-if-stage wave-vcd wave-if-stage-vcd lint lint-if-stage clean clean-build

all: test

test: test-if-stage

wave: wave-if-stage

wave-vcd: wave-if-stage-vcd

test-if-stage:
	$(MAKE) -C tests/cocotb/if_stage test

wave-if-stage:
	$(MAKE) -C tests/cocotb/if_stage wave

wave-if-stage-vcd:
	$(MAKE) -C tests/cocotb/if_stage wave-vcd

clean: 
	rm -rf build
