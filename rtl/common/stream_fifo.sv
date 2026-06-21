// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 不暴露全条目的 FIFO 接口。存储和边界行为统一由 peek_fifo 实现；未连接的
// 全条目观察逻辑会在综合时删除。
module stream_fifo #(
  parameter int unsigned Depth = 2,
  parameter bit FallThrough = 1'b0,
  parameter bit SameCycleRW = 1'b0,
  parameter type T = logic,
  parameter int unsigned CountW = (Depth > 1) ? $clog2(Depth + 1) : 1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  output logic [CountW-1:0] usage_o,

  input T data_i,
  input logic valid_i,
  output logic ready_o,

  output T data_o,
  output logic valid_o,
  input logic ready_i
);

  peek_fifo #(
    .Depth(Depth),
    .FallThrough(FallThrough),
    .SameCycleRW(SameCycleRW),
    .T(T)
  ) u_fifo (
    .clk_i,
    .rst_ni,
    .flush_i,
    .usage_o,
    .data_i,
    .valid_i,
    .ready_o,
    .data_o,
    .valid_o,
    .ready_i,
    .data_all_o(  /* unused */),
    .valid_all_o(  /* unused */)
  );

endmodule
