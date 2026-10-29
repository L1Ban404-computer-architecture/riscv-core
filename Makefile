# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

# 综合检查、面积分析、I-cache 形式化与离线仿真分别在组件目录里。
.PHONY: check perf check-branch-predictor formal-icache cachesim branchsim \
        cachesim-sim cachesim-run branchsim-sim branchsim-run sim run clean

check perf:
	$(MAKE) -C rtl $@

formal-icache:
	$(MAKE) -C formal/icache formal-icache

cachesim-sim cachesim-run:
	$(MAKE) -C cachesim $(patsubst cachesim-%,%,$@)

branchsim-sim branchsim-run:
	$(MAKE) -C branchsim $(patsubst branchsim-%,%,$@)

clean:
	$(MAKE) -C rtl clean
	$(MAKE) -C formal/icache clean
	$(MAKE) -C cachesim clean
	$(MAKE) -C branchsim clean
	rm -rf build
