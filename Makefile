# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# 综合检查、面积分析、I-cache 形式化和 cachesim 分别在组件目录里。
.PHONY: check perf formal-icache cachesim pctrace sim run clean

check perf:
	$(MAKE) -C rtl $@

formal-icache:
	$(MAKE) -C formal/icache formal-icache

cachesim pctrace sim run:
	$(MAKE) -C cachesim $@

clean:
	$(MAKE) -C rtl clean
	$(MAKE) -C formal/icache clean
	$(MAKE) -C cachesim clean
	rm -rf build
