// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 行为级单口 1RW 存储原语，供后续替换为编译器宏或工艺 SRAM。
//
// 全宽写入，没有写掩码。读延迟一拍：en_i 且 !we_i 的地址在下一拍出现在
// rdata_o；写与读同一拍采用 read-first，en_i 为低时保持 rdata_o。存储和输出
// 寄存器都不复位。
`include "common/assertions.svh"

module sram_1rw #(
  parameter int unsigned Width = 32,
  parameter int unsigned Depth = 16,
  localparam int unsigned AddrW = (Depth > 1) ? $clog2(Depth) : 1
) (
  input logic clk_i,

  input  logic             en_i,
  input  logic             we_i,
  input  logic [AddrW-1:0] addr_i,
  input  logic [Width-1:0] wdata_i,
  output logic [Width-1:0] rdata_o
);

  logic [Width-1:0] mem[Depth];
  logic [AddrW-1:0] mem_addr;

  assign mem_addr = (Depth == 1) ? '0 : addr_i;

  always_ff @(posedge clk_i) begin
    if (en_i) begin
      if (we_i) mem[mem_addr] <= wdata_i;
      rdata_o <= mem[mem_addr];
    end
  end

  if (Depth == 1) begin : gen_unused_addr
    logic unused_addr;
    assign unused_addr = addr_i[0];
  end

  `ASSERT_INIT(Sram1rwWidthValid, Width > 0)
  `ASSERT_INIT(Sram1rwDepthValid, Depth > 0)

endmodule
