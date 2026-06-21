// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单入口 fall-through 弹性寄存器。空载时组合旁路，满载时支持同拍替换。
module fall_through_register #(
  parameter type T = logic
) (
  input logic clk_i,
  input logic rst_ni,
  input logic clr_i,

  input logic valid_i,
  output logic ready_o,
  input T data_i,

  output logic valid_o,
  input logic ready_i,
  output T data_o
);

  stream_fifo #(
    .Depth(1),
    .FallThrough(1'b1),
    .SameCycleRW(1'b1),
    .T(T)
  ) u_fifo (
    .clk_i,
    .rst_ni,
    .flush_i(clr_i),
    .usage_o(  /* unused */),
    .data_i,
    .valid_i,
    .ready_o,
    .data_o,
    .valid_o,
    .ready_i
  );

endmodule
