# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

ROOT := $(abspath ../..)
YOSYS ?= yosys
RVE ?= 1
RUNNER_HOME ?= $(abspath $(ROOT)/../riscv-runner)
include $(RUNNER_HOME)/api/generated/rv_contract.mk

CROSS_COMPILE ?= riscv64-unknown-elf-
BUILD := $(ROOT)/build/tests/memory
ISA := $(if $(filter y,$(CONFIG_RVE)),rv32e,rv32i)_zicsr
ABI := $(if $(filter y,$(CONFIG_RVE)),ilp32e,ilp32)
DUT ?= npc
REF ?= nemu
# CLINT 的非法宽度/写入由实际平台拒绝，用 REF= CHECK_ACCESS_FAULTS=1 自检。
CHECK_ACCESS_FAULTS ?= 0
IMAGE := $(BUILD)/memory-$(CHECK_ACCESS_FAULTS)

.PHONY: check run
check:
	$(YOSYS) -Q -T -p 'plugin -i slang; read_slang -D SYNTHESIS -DRISCV_CORE_RVE=$(RVE) --single-unit --top data_lanes $(ROOT)/rtl/core/riscv_core_pkg.sv $(ROOT)/rtl/core/units/load_data_unit.sv $(ROOT)/rtl/core/units/store_data_unit.sv data_lanes.sv; prep -top data_lanes -flatten; sat -verify -prove correct 1 -show-inputs'

run: $(IMAGE).bin
	$(MAKE) -C $(RUNNER_HOME) run DUT=$(DUT) REF=$(REF) IMAGE=$< \
		LOG_DIR=$(BUILD)/logs-$(DUT)

$(IMAGE).elf: memory.S $(RUNNER_HOME)/api/generated/rv_contract.mk Makefile
	mkdir -p $(BUILD)
	$(CROSS_COMPILE)gcc -march=$(ISA) -mabi=$(ABI) -nostdlib -nostartfiles \
		-Wl,--no-relax,-Ttext=$(CONFIG_IMAGE_LOAD_BASE),-e,_start \
		-DTEST_RAM=$(CONFIG_MEMORY_SRAM_BASE) \
		-DTEST_MTIME=$(CONFIG_DEVICE_CLINT_BASE)+$(CONFIG_DEVICE_CLINT_MTIME_OFFSET) \
		-DCHECK_ACCESS_FAULTS=$(CHECK_ACCESS_FAULTS) $< -o $@

$(IMAGE).bin: $(IMAGE).elf
	$(CROSS_COMPILE)objcopy -O binary -j .text $< $@
