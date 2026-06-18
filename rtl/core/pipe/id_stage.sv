// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

/* verilator lint_off UNUSEDSIGNAL */
module id_stage (
  input logic clk_i,
  input logic rst_ni,

  // IF -> ID 事务通道。ID stage 消费 IF 产生的 fetch/debug 事务，并在内部
  // 完成译码、立即数生成和寄存器堆读取。
  input logic if_id_valid_i,
  output logic if_id_ready_o,
  input if_id_bus_t if_id_bus_i,

  // WB -> ID 写回请求。寄存器堆预计归属 ID stage 内部，因此顶层只把
  // 写回事务送回 ID，不直接暴露寄存器堆端口。
  input wb_req_bus_t wb_req_i,

  // ID -> EX 事务通道。id_ex 的寄存器墙深度初步约束为 1，并由 ID stage
  // 内部维护；EX 只消费该事务，不对它执行 redirect 冲刷。
  output logic id_ex_valid_o,
  input logic id_ex_ready_i,
  output id_ex_bus_t id_ex_bus_o
);

  // 占位实现：当前只固定 ready/valid 边界，后续在此加入 decoder、
  // imm_gen、regfile 以及 id_ex 深度为 1 的事务保持逻辑。
  assign if_id_ready_o = id_ex_ready_i;
  assign id_ex_valid_o = 1'b0;
  assign id_ex_bus_o = '0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
