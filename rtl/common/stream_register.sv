// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单入口时序弹性寄存器，在 ready/valid 通路上保存一笔事务。
module stream_register #(
  parameter type T = logic
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // 输入事务
  input logic valid_i,
  output logic ready_o,
  input T data_i,

  // 输出事务
  output logic valid_o,
  input logic ready_i,
  output T data_o
);

  stream_fifo #(
    .Depth(1),
    .FallThrough(1'b0),
    .SameCycleRW(1'b1),
    .T(T)
  ) u_fifo (
    .clk_i,
    .rst_ni,
    .flush_i,
    .usage_o(  /* 未使用 */),
    .data_i,
    .valid_i,
    .ready_o,
    .data_o,
    .valid_o,
    .ready_i
  );

endmodule
