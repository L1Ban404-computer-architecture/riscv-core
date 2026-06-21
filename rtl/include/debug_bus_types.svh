// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef DEBUG_BUS_TYPES_SVH
`define DEBUG_BUS_TYPES_SVH

`include "transaction_bus_types.svh"

// Debug 总线只描述“这条指令发生了什么”，不应反向参与功能控制。
// wb_debug_bus_t.valid 为 1 时表示一条指令在架构层面退休。
typedef struct packed {fetch_bus_t fetch;} if_debug_bus_t;

typedef struct packed {
  if_debug_bus_t if_debug;
  reg_addr_bus_t reg_addr;
  decode_ctrl_bus_t ctrl;
} id_debug_bus_t;

typedef struct packed {
  id_debug_bus_t id_debug;
  redirect_bus_t redirect;
  word_t alu_result;
} ex_debug_bus_t;

typedef struct packed {
  ex_debug_bus_t ex_debug;
  mem_req_bus_t mem_req;
  mem_rsp_bus_t mem_rsp;
} mem_debug_bus_t;

typedef struct packed {
  // 面向上层仿真环境，语义等价于展开后的 wb_debug_bus_t。
  logic valid;
  fetch_bus_t fetch;
  reg_addr_bus_t reg_addr;
  decode_ctrl_bus_t ctrl;
  redirect_bus_t redirect;
  word_t alu_result;
  mem_req_bus_t mem_req;
  mem_rsp_bus_t mem_rsp;
  wb_req_bus_t wb_req;
} core_debug_bus_t;

`endif
