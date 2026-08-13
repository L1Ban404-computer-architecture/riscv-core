// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 处理器各子系统共享的最小基础类型 package。本 package 位于依赖图最底层，
// 不依赖 core、bus 或 cache；这里只保存跨子系统必须保持一致的物理宽度、标量
// 数据类型，禁止加入任何具体协议、子系统私有结构或 assertion 实现。
package riscv_common_pkg;

  // 当前实现的数据与地址宽度均为 32 位，每个数据字由 4 个 8 位 byte lane 组成。
  // 总线、核心和 cache 均从这里取得相同宽度，避免各自重复定义后产生 ABI 偏差。
  parameter int unsigned XLen = 32;
  parameter int unsigned ByteW = 8;
  parameter int unsigned StrbW = XLen / ByteW;

  typedef logic [XLen-1:0] word_t;
  typedef logic [StrbW-1:0] byte_en_t;

endpackage
