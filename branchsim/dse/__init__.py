# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

"""分支预测参数扫描与离线报告。"""

FULL_PC_ENTRY_BITS = 30 + 32 + 3
REFERENCE_ENTRIES = 8
FF_BUDGET = REFERENCE_ENTRIES * FULL_PC_ENTRY_BITS
PC_WIDTHS = (4, 8, 16, 30)
TARGET_WIDTHS = (4, 8, 16, 32)
