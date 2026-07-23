// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef DEBUG_BUS_TYPES_SVH
`define DEBUG_BUS_TYPES_SVH

`include "transaction_bus_types.svh"

// 退休元数据只描述“这条指令退休时对外可观察到什么”，不反向参与功能控制。
typedef enum logic [1:0] {
  RETIRE_MEM_NONE = 2'd0,
  RETIRE_MEM_READ = 2'd1,
  RETIRE_MEM_WRITE = 2'd2
} retire_mem_op_e;

typedef struct packed {
  instruction_bus_t instruction;
  retire_mem_op_e mem_op;
  mem_size_e mem_size;
  word_t mem_addr;
  word_t mem_data;
  logic redirect_valid;
  pc_t redirect_target_pc;
} retire_meta_bus_t;

typedef struct packed {
  // 面向上层仿真环境的最后一次退休指令快照；有效脉冲由独立信号提供。
  pc_t pc;
  instr_t instr;
  logic gpr_we;
  reg_addr_t gpr_waddr;
  word_t gpr_wdata;
  retire_mem_op_e mem_op;
  mem_size_e mem_size;
  word_t mem_addr;
  word_t mem_data;
  logic redirect_valid;
  pc_t redirect_target_pc;
  csr_state_bus_t csr;
} core_retire_debug_bus_t;

// 面向仿真环境的最后一次退休状态快照，与退休有效脉冲分离。
typedef struct packed {
  logic [63:0] cycle_count;
  logic [63:0] instret_count;
  logic trap;
  logic intr;
  word_t cause;
  word_t tval;
} core_state_debug_bus_t;

`endif
