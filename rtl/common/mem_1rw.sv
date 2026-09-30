// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 行为级 1R1W 存储原语，用寄存器阵列模拟，便于在无宏 SRAM 的工艺上综合。
//
// 读、写地址独立。全宽写入，没有写掩码。`CombRead=0`（默认）为同步读：`ren_i`
// 的 `raddr_i` 下一拍出现在 `rdata_o`，`ren_i` 为低时保持。`CombRead=1` 为组合读：
// `rdata_o` 组合反映 `mem[raddr_i]`，`ren_i` 不参与。同地址同拍写与读相对时钟为
// read-first（写在时钟沿更新，组合读在该沿前仍见旧值）。存储和同步读输出都不复位。
`include "common/assertions.svh"

module mem_1rw #(
  parameter int unsigned Width = 32,
  parameter int unsigned Depth = 16,
  parameter bit CombRead = 1'b0,
  localparam int unsigned AddrW = (Depth > 1) ? $clog2(Depth) : 1
) (
  input logic clk_i,

  input  logic             ren_i,
  input  logic [AddrW-1:0] raddr_i,
  output logic [Width-1:0] rdata_o,

  input logic             wen_i,
  input logic [AddrW-1:0] waddr_i,
  input logic [Width-1:0] wdata_i
);

  logic [Width-1:0] mem[Depth];
  logic [AddrW-1:0] mem_raddr;
  logic [AddrW-1:0] mem_waddr;

  assign mem_raddr = (Depth == 1) ? '0 : raddr_i;
  assign mem_waddr = (Depth == 1) ? '0 : waddr_i;

  always_ff @(posedge clk_i) begin
    if (wen_i) mem[mem_waddr] <= wdata_i;
  end

  if (CombRead) begin : gen_comb_read
    assign rdata_o = mem[mem_raddr];

    logic unused_ren;
    assign unused_ren = ren_i;
  end else begin : gen_sync_read
    always_ff @(posedge clk_i) begin
      if (ren_i) rdata_o <= mem[mem_raddr];
    end
  end

  if (Depth == 1) begin : gen_unused_addr
    logic unused_addr;
    assign unused_addr = ^{raddr_i[0], waddr_i[0]};
  end

  `ASSERT_INIT(Mem1rwWidthValid, Width > 0)
  `ASSERT_INIT(Mem1rwDepthValid, Depth > 0)

endmodule
