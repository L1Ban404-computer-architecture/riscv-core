// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单入口 fall-through 弹性寄存器。
// 空载时组合旁路输入，发生反压时保存一笔事务。
module fall_through_register #(
  parameter type T = logic,
  // 前端改道需要当拍屏蔽旧事务；默认仅在时钟沿清空缓冲。
  parameter bit FlushMask = 1'b0
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

  logic fifo_valid;
  logic transfer_enable;

  assign transfer_enable = !FlushMask || !flush_i;
  assign valid_o = fifo_valid && transfer_enable;

  stream_fifo #(
    .Depth(1),
    .FallThrough(1'b1),
    .SameCycleRW(1'b1),
    .T(T)
  ) u_fifo (
    .clk_i,
    .rst_ni,
    .flush_i,
    .usage_o(  /* 未使用 */),
    .data_i,
    .valid_i(valid_i && transfer_enable),
    .ready_o,
    .data_o,
    .valid_o(fifo_valid),
    .ready_i(ready_i && transfer_enable)
  );

endmodule
