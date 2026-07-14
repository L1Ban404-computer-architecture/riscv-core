// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef PIPELINE_BUS_TYPES_SVH
`define PIPELINE_BUS_TYPES_SVH

`include "debug_bus_types.svh"

// 阶段边界处随指令移动的 payload。exception 一旦有效便保持上游优先；
// 后级只允许补充尚未出现的异常，并必须抑制该指令的普通架构副作用。
// 寄存器墙/FIFO 由各 stage 内部维护。
typedef struct packed {
  fetch_bus_t fetch;
  exception_bus_t exception;
  if_debug_bus_t debug;
} if_id_bus_t;

typedef struct packed {
  fetch_bus_t fetch;
  reg_addr_bus_t reg_addr;
  exec_data_bus_t exec_data;
  decode_ctrl_bus_t ctrl;
  exception_bus_t exception;
  id_debug_bus_t debug;
} id_ex_bus_t;

typedef struct packed {
  mem_req_bus_t mem_req;
  wb_req_bus_t wb_req;
  exception_bus_t exception;
  commit_ctrl_bus_t commit;
  ex_debug_bus_t debug;
} ex_mem_bus_t;

typedef struct packed {
  wb_req_bus_t wb_req;
  exception_bus_t exception;
  commit_ctrl_bus_t commit;
  mem_debug_bus_t debug;
} mem_wb_bus_t;

`endif
