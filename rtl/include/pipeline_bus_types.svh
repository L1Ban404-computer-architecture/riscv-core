// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef PIPELINE_BUS_TYPES_SVH
`define PIPELINE_BUS_TYPES_SVH

`include "debug_bus_types.svh"

// 阶段边界处随指令移动的 payload。exception 一旦有效便保持上游优先；
// 后级只允许补充尚未出现的异常，并必须抑制该指令的普通架构副作用。
// 寄存器墙/FIFO 由各 stage 内部维护。
typedef struct packed {
  pc_t pc;
  instr_t instr;
  exception_bus_t exception;
  core_retire_debug_bus_t debug;
} if_id_bus_t;

typedef struct packed {
  pc_t pc;
  instr_t instr;
  reg_addr_bus_t reg_addr;
  exec_data_bus_t exec_data;
  execute_ctrl_bus_t ctrl;
  exception_bus_t exception;
  core_retire_debug_bus_t debug;
} id_ex_bus_t;

typedef struct packed {
  // 精确异常提交使用的功能 PC；不得从 debug payload 反向取得。
  pc_t pc;
  mem_req_bus_t mem_req;
  wb_req_bus_t wb_req;
  exception_bus_t exception;
  commit_ctrl_bus_t commit;
  core_retire_debug_bus_t debug;
} ex_mem_bus_t;

typedef struct packed {
  pc_t pc;
  wb_req_bus_t wb_req;
  exception_bus_t exception;
  commit_ctrl_bus_t commit;
  core_retire_debug_bus_t debug;
} mem_wb_bus_t;

`endif
