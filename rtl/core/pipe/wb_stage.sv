// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

/* verilator lint_off UNUSEDSIGNAL */
module wb_stage (
  input logic clk_i,
  input logic rst_ni,

  // MEM -> WB 事务通道。WB 是当前五级流水中指令退休的位置。
  input logic mem_wb_valid_i,
  output logic mem_wb_ready_o,
  input mem_wb_bus_t mem_wb_bus_i,

  // 写回请求回送给 ID stage 内部未来的寄存器堆，同时也提供给 EX stage
  // 作为最老一级的数据前递来源。
  output wb_req_bus_t wb_req_o,

  // 扁平化退休追踪总线。仿真环境优先观察该端口，而不是逐层访问嵌套
  // debug bus。
  output core_debug_bus_t core_debug_o
);

  // 占位实现：当前不退休真实指令。后续 WB 会根据 mem_wb_bus_i 展开并填充
  // core_debug_o，同时把最终写回数据送回 ID。
  assign mem_wb_ready_o = 1'b1;
  assign wb_req_o = '0;
  assign core_debug_o = '0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
