// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 两张只读指令表。每个字地址一条指令，整段迹内不变，只覆盖求解器地址空间。
// 更宽的字地址截掉高位。invalidate_i 上升沿切换当前表，保持为高时不翻转。
// AXI 读和响应比较都读当前表。
module fv_imem #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned SolverAddrWidth = 12,
  localparam int unsigned WordAddrW = AddrWidth - 2,
  localparam int unsigned SolverWordAddrW = SolverAddrWidth - 2
) (
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,
  input logic [WordAddrW-1:0] axi_word_addr_i,
  output logic [31:0] axi_instr_o,
  input logic [WordAddrW-1:0] rsp_word_addr_i,
  output logic [31:0] rsp_instr_o
);

  logic [31:0] mem0[1 << SolverWordAddrW];
  logic [31:0] mem1[1 << SolverWordAddrW];
  logic image_q;
  logic invalidate_q;
  logic [SolverWordAddrW-1:0] axi_word_addr;
  logic [SolverWordAddrW-1:0] rsp_word_addr;

  assign axi_word_addr = axi_word_addr_i[SolverWordAddrW-1:0];
  assign rsp_word_addr = rsp_word_addr_i[SolverWordAddrW-1:0];
  assign axi_instr_o = image_q ? mem1[axi_word_addr] : mem0[axi_word_addr];
  assign rsp_instr_o = image_q ? mem1[rsp_word_addr] : mem0[rsp_word_addr];

  initial begin
    image_q = 1'b0;
    invalidate_q = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      image_q <= 1'b0;
      invalidate_q <= 1'b0;
    end else begin
      invalidate_q <= invalidate_i;
      if (invalidate_i && !invalidate_q) image_q <= ~image_q;
    end
  end

endmodule
