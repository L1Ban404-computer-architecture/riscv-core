// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

package riscv_core_pkg;

  // 各分片按照类型依赖顺序聚合。模块仍统一 import riscv_core_pkg::*，避免
  // 文件职责拆分影响设计侧的命名空间和端口声明。
  `include "riscv_core_config.svh"
  `include "riscv_isa_config.svh"
  `include "core_bus_types.svh"
  `include "axi4_bus_types.svh"
  `include "transaction_bus_types.svh"
  `include "debug_bus_types.svh"
  `include "pipeline_bus_types.svh"

endpackage
