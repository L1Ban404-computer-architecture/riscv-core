// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "common/assertions.svh"

// 退休观察用的顺序在途队列。
//
// 入口/出口 fire 对应被观察阶段的输入/输出握手；不向流水施加反压。
// 同拍入队出队时组合出口仍为队头，posedge 后切换，与非 fall-through
// SameCycleRW 弹性寄存器一致。Depth 为该阶段最大在途事务数。
`ifndef SYNTHESIS
module retire_inflight_queue
#(
  parameter int unsigned Depth = 1,
  parameter type T = logic
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // 顺序入队 / 出队
  input logic in_fire_i,
  input T in_data_i,
  input logic out_fire_i,
  output T out_data_o
);

  logic ready;
  logic valid;

  stream_fifo #(
    .Depth(Depth),
    .FallThrough(1'b0),
    .SameCycleRW(1'b1),
    .T(T)
  ) u_fifo (
    .clk_i,
    .rst_ni,
    .flush_i,
    .usage_o(  /* 未使用 */),
    .data_i(in_data_i),
    .valid_i(in_fire_i),
    .ready_o(ready),
    .data_o(out_data_o),
    .valid_o(valid),
    .ready_i(out_fire_i)
  );

  // verilog_format: off
  `ASSERT(RetireQueueNoOverflow, in_fire_i |-> ready, clk_i, !rst_ni || flush_i,
          "Retire inflight queue overflow; increase MaxInflight.")
  `ASSERT(RetireQueueNoUnderflow, out_fire_i |-> valid, clk_i, !rst_ni || flush_i,
          "Retire inflight queue underflow; input/output fires are not in order.")
  // verilog_format: on

endmodule
`endif
