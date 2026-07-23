// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef PIPELINE_BUS_TYPES_SVH
`define PIPELINE_BUS_TYPES_SVH

`include "debug_bus_types.svh"

// 阶段边界处随指令移动的 payload。exception 一旦有效便保持上游优先；
// 后级只允许补充尚未出现的异常，并必须抑制该指令的普通架构副作用。
// 寄存器墙/FIFO 由各 stage 内部维护。
typedef struct packed {
  instruction_bus_t instruction;
  exception_bus_t exception;
} if_id_bus_t;

typedef struct packed {
  instruction_bus_t instruction;
  reg_addr_bus_t reg_addr;
  exec_data_bus_t exec_data;
  execute_ctrl_bus_t ctrl;
  exception_bus_t exception;
} id_ex_bus_t;

typedef struct packed {
  mem_req_bus_t mem_req;
  wb_req_bus_t wb_req;
  exception_bus_t exception;
  commit_ctrl_bus_t commit;
  retire_meta_bus_t retire;
} ex_mem_bus_t;

typedef struct packed {
  wb_req_bus_t wb_req;
  exception_bus_t exception;
  commit_ctrl_bus_t commit;
  retire_meta_bus_t retire;
} mem_wb_bus_t;

`endif
