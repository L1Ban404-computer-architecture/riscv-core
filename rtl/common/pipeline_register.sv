// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "common/assertions.svh"

// 带握手稳定断言的单入口流水弹性寄存器。
//
// 功能上等价于 stream_register；flush 当拍不检查 payload/valid 保持。
module pipeline_register #(
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

  stream_register #(
    .T(T)
  ) u_reg (
    .clk_i,
    .rst_ni,
    .flush_i,
    .valid_i,
    .ready_o,
    .data_i,
    .valid_o,
    .ready_i,
    .data_o
  );

  // verilog_format: off
  `ASSERT_STABLE(
    PayloadStable,
    valid_o,
    ready_i,
    data_o,
    T'(0),
    clk_i,
    !rst_ni || flush_i,
    "Pipeline payload must remain stable while valid is waiting for ready."
  )

  `ASSERT(
    ValidStable,
    valid_o && !ready_i |=> valid_o,
    clk_i,
    !rst_ni || flush_i,
    "Pipeline valid must remain asserted until ready."
  )
  // verilog_format: on

endmodule
