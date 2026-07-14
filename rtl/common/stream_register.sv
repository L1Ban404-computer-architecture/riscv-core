// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单入口、非 fall-through 的弹性寄存器。满载且输出被消费时可同拍替换。
module stream_register #(
  parameter type T = logic
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  input logic valid_i,
  output logic ready_o,
  input T data_i,

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
    .usage_o(  /* unused */),
    .data_i,
    .valid_i,
    .ready_o,
    .data_o,
    .valid_o,
    .ready_i
  );

endmodule
