// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 核心、总线和 Cache 共用的基础宽度与标量类型。
package riscv_common_pkg;

  // 当前实现的数据与地址宽度均为 32 位，每个数据字由 4 个 8 位 byte lane 组成。
  // 总线、核心和 cache 均从这里取得相同宽度，避免各自重复定义后产生 ABI 偏差。
  parameter int unsigned XLen = 32;
  parameter int unsigned ByteW = 8;
  parameter int unsigned StrbW = XLen / ByteW;

  typedef logic [XLen-1:0] word_t;
  typedef logic [StrbW-1:0] byte_en_t;

endpackage
