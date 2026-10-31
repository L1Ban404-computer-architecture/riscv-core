# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# I-cache 取指一致性：复位后 20 拍的有界检查。产物在项目根 build/formal/icache/。
# sby 的文件路径相对当前工作目录，所以回到仓库根再运行。
.DEFAULT_GOAL := formal-icache
SBY ?= sby
ROOT := $(abspath ../..)
BUILD_DIR := $(ROOT)/build/formal/icache
SBY_CONFIG := $(BUILD_DIR)/icache_fetch.sby

# 验证读入 rtl/ 下全部 SystemVerilog，再加本目录的形式化顶层。
HDL_SRCS := $(shell cd $(ROOT) && find rtl -type f \( -name '*.sv' -o -name '*.svh' \) -print | LC_ALL=C sort)
HDL_SRCS += $(shell cd $(ROOT) && find formal/icache -type f -name 'fv_*.sv' -print | LC_ALL=C sort)
ifeq ($(strip $(HDL_SRCS)),)
$(error 未找到 SystemVerilog 源文件)
endif

.PHONY: formal-icache

formal-icache:
	mkdir -p "$(BUILD_DIR)"
	cp icache_fetch.sby "$(SBY_CONFIG)"
	printf '%s\n' '[script]' 'plugin -i slang' \
	  'read_slang --no-synthesis-define --single-unit --top fv_icache_fetch $(HDL_SRCS)' \
	  'prep -top fv_icache_fetch' '' '[files]' >> "$(SBY_CONFIG)"
	for src in $(HDL_SRCS); do printf '%s %s\n' "$$src" "$$src"; done >> "$(SBY_CONFIG)"
	cd "$(ROOT)" && $(SBY) -f --prefix "$(BUILD_DIR)/icache_fetch" "$(SBY_CONFIG)"
