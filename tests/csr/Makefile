# CSR 架构回归：沿用 runner 契约，在实际核心上执行并逐指令差分。
ROOT := $(abspath ../..)
RUNNER_HOME ?= $(abspath $(ROOT)/../riscv-runner)
include $(RUNNER_HOME)/api/generated/rv_contract.mk

CROSS_COMPILE ?= riscv64-unknown-elf-
BUILD := $(ROOT)/build/tests/csr
ISA := $(if $(filter y,$(CONFIG_RVE)),rv32e,rv32i)_zicsr
ABI := $(if $(filter y,$(CONFIG_RVE)),ilp32e,ilp32)
DUT ?= npc
REF ?= nemu
# NEMU 尚未屏蔽软件写入 mepc 的低两位；该项用 REF= CHECK_MEPC_WARL=1 自检。
CHECK_MEPC_WARL ?= 0
IMAGE := $(BUILD)/csr-$(CHECK_MEPC_WARL)

.PHONY: run
run: $(IMAGE).bin
	$(MAKE) -C $(RUNNER_HOME) run DUT=$(DUT) REF=$(REF) IMAGE=$< \
		LOG_DIR=$(BUILD)/logs

$(IMAGE).elf: csr.S $(RUNNER_HOME)/api/generated/rv_contract.mk Makefile
	mkdir -p $(BUILD)
	$(CROSS_COMPILE)gcc -march=$(ISA) -mabi=$(ABI) -nostdlib -nostartfiles \
		-Wl,--no-relax,-Ttext=$(CONFIG_IMAGE_LOAD_BASE),-e,_start \
		-DTEST_RAM=$(CONFIG_MEMORY_SRAM_BASE) \
		-DCHECK_MEPC_WARL=$(CHECK_MEPC_WARL) $< -o $@

$(IMAGE).bin: $(IMAGE).elf
	$(CROSS_COMPILE)objcopy -O binary -j .text $< $@
