# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# I-cache 取指一致性：复位后 20 拍的有界检查。产物在 build/。
# sby 的文件路径相对当前工作目录，所以回到仓库根再运行。
SBY ?= sby
ROOT := $(abspath ../..)

# 验证读入 rtl/ 下全部 SystemVerilog，再加本目录的形式化顶层。排除两侧的 build/。
HDL_SRCS := $(shell cd $(ROOT) && find rtl \( -path rtl/build -prune \) -o -type f \( -name '*.sv' -o -name '*.svh' \) -print | LC_ALL=C sort)
HDL_SRCS += $(shell cd $(ROOT) && find formal/icache \( -path formal/icache/build -prune \) -o -type f -name 'fv_*.sv' -print | LC_ALL=C sort)
ifeq ($(strip $(HDL_SRCS)),)
$(error 未找到 SystemVerilog 源文件)
endif

.PHONY: formal-icache clean

formal-icache:
	mkdir -p build
	cp icache_fetch.sby build/icache_fetch.sby
	printf '%s\n' '[script]' 'plugin -i slang' \
	  'read_slang --no-synthesis-define --single-unit --top fv_icache_fetch $(HDL_SRCS)' \
	  'prep -top fv_icache_fetch' '' '[files]' >> build/icache_fetch.sby
	for src in $(HDL_SRCS); do printf '%s %s\n' "$$src" "$$src"; done >> build/icache_fetch.sby
	cd $(ROOT) && $(SBY) -f --prefix formal/icache/build/icache_fetch formal/icache/build/icache_fetch.sby

clean:
	rm -rf build
