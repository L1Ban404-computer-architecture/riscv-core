// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单入口时序弹性寄存器，在 ready/valid 通路上保存一笔事务。
// flush 当拍屏蔽旧输出并释放容量，时钟沿仍接收有效输入；上游负责取消旧路径输入。
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

  logic valid_q;
  T data_q;

  assign ready_o = flush_i || !valid_q || ready_i;
  assign valid_o = valid_q && !flush_i;
  assign data_o = data_q;

  // 数据不复位；无效内容始终由 valid 屏蔽。
  always_ff @(posedge clk_i) begin
    if (rst_ni && valid_i && ready_o) data_q <= data_i;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) valid_q <= 1'b0;
    else if (ready_o) valid_q <= valid_i;
  end

endmodule
