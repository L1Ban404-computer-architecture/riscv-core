# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# I-cache 取指一致性：复位后 20 拍的有界检查。产物在 build/。
# sby 的文件路径相对当前工作目录，所以回到仓库根再运行。
SBY ?= sby
ROOT := $(abspath ../..)

.PHONY: formal-icache clean

formal-icache:
	mkdir -p build
	cd $(ROOT) && $(SBY) -f --prefix formal/icache/build/icache_fetch formal/icache/icache_fetch.sby

clean:
	rm -rf build
