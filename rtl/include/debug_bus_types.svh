// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef DEBUG_BUS_TYPES_SVH
`define DEBUG_BUS_TYPES_SVH

`include "transaction_bus_types.svh"

// Debug 总线只描述“这条指令退休时对外可观察到什么”，不应反向参与功能控制。
// 各级 debug payload 直接列出本级以后仍需要的字段，避免逐级嵌套。
typedef struct packed {
  pc_t pc;
  instr_t instr;
} if_debug_bus_t;

typedef struct packed {
  pc_t pc;
  instr_t instr;
} id_debug_bus_t;

typedef struct packed {
  pc_t pc;
  instr_t instr;
  logic mem_valid;
  logic mem_write;
  mem_size_e mem_size;
  word_t mem_addr;
  word_t mem_wdata;
  logic redirect_valid;
  pc_t redirect_target_pc;
} ex_debug_bus_t;

typedef struct packed {
  pc_t pc;
  instr_t instr;
  logic mem_valid;
  logic mem_write;
  mem_size_e mem_size;
  word_t mem_addr;
  word_t mem_wdata;
  logic redirect_valid;
  pc_t redirect_target_pc;
} mem_debug_bus_t;

typedef struct packed {
  // 面向上层仿真环境的退休追踪总线。valid 为 1 表示本周期退休一条指令。
  logic valid;
  pc_t pc;
  instr_t instr;
  logic gpr_we;
  reg_addr_t gpr_waddr;
  word_t gpr_wdata;
  logic mem_valid;
  logic mem_write;
  mem_size_e mem_size;
  word_t mem_addr;
  word_t mem_wdata;
  logic redirect_valid;
  pc_t redirect_target_pc;
} core_debug_bus_t;

`endif
