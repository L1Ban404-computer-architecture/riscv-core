// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

/* verilator lint_off UNUSEDSIGNAL */
module ex_stage (
  input logic clk_i,
  input logic rst_ni,

  // ID -> EX 事务通道。进入 EX 的指令被视为已确认有效，不再被 redirect
  // 冲刷；若数据前递不可用，EX 通过 id_ex_ready_o 反压 ID。
  input logic id_ex_valid_i,
  output logic id_ex_ready_o,
  input id_ex_bus_t id_ex_bus_i,

  // 数据前递来源。EX stage 内部根据较老指令的写回请求自行判断：
  // - 若 rd 匹配且 data_valid 为 1，则选择对应前递数据；
  // - 若 rd 匹配但 data_valid 为 0，则拉低 id_ex_ready_o 阻塞当前事务。
  input forward_src_bus_t forward_src_i,

  // EX -> IF redirect。该信号单向指向前端，只影响更年轻的 IF/ID 事务。
  output redirect_bus_t redirect_o,

  // EX 产生的写回候选，用于数据前递。对 ALU 类指令，data_valid 通常会在
  // EX 结束时成立；对 load 类指令，应等 MEM 返回后再由 MEM 提供有效数据。
  output wb_req_bus_t ex_wb_req_o,

  // EX -> MEM 事务通道。EX 负责形成访存请求、写回候选和 EX debug 信息。
  output logic ex_mem_valid_o,
  input logic ex_mem_ready_i,
  output ex_mem_bus_t ex_mem_bus_o
);

  // 占位实现：先只定义结构互联，真实 ALU/branch/forward mux 后续补入。
  assign id_ex_ready_o = ex_mem_ready_i;
  assign redirect_o = '0;
  assign ex_wb_req_o = '0;
  assign ex_mem_valid_o = 1'b0;
  assign ex_mem_bus_o = '0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
