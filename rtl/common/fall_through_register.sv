// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单入口 fall-through 弹性寄存器。
// 空载时组合旁路输入，发生反压时保存一笔事务。
// 默认 flush 清空并停止接收；AcceptInputOnFlush 允许当拍接收新事务，下一拍输出。
module fall_through_register #(
  parameter bit AcceptInputOnFlush = 1'b0,
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

  logic valid_q;
  T data_q;

  assign ready_o = flush_i ? AcceptInputOnFlush : (!valid_q || ready_i);
  assign valid_o = (valid_q || valid_i) && !flush_i;
  assign data_o = valid_q ? data_q : data_i;

  // 空载且输出直接接收时无需保存；flush 当拍禁止直通，必须保存新输入。
  always_ff @(posedge clk_i) begin
    if (rst_ni && valid_i && ready_o && (flush_i || valid_q || !ready_i)) data_q <= data_i;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) valid_q <= 1'b0;
    else if (flush_i) valid_q <= AcceptInputOnFlush && valid_i;
    else if (ready_o) valid_q <= valid_i && (valid_q || !ready_i);
  end

endmodule
