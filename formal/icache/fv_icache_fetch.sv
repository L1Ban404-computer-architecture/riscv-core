// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 取指形式化顶层。icache 的 CPU 侧接 core_bus_if，存储器侧接 axi4_if。
// 求解器地址为 12 位，由 fv_cpu_fetch 补成 icache 地址。
// rst_ni 初始为复位，第一拍后释放并保持。
module fv_icache_fetch
  import riscv_bus_pkg::*;
  import icache_pkg::*;
#(
  // 求解器字节地址，覆盖 2^10 个字。
  parameter int unsigned SolverAddrWidth = 12,
  // icache 与两条总线的字节地址。
  parameter int unsigned AddrWidth = ICacheAddrWidth,
  parameter int unsigned DataWidth = ICacheDataWidth,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = ICACHE_AXI_ID,
  // 8 字节行，在数据总线上按两拍 INCR 回填。
  parameter int unsigned BlockBytes = 8,
  parameter int unsigned SetCount = ICacheSetCount,
  parameter int unsigned WayCount = ICacheWayCount,
  parameter icache_replacement_policy_e ReplacementPolicy = ICacheReplacementPolicy,
  localparam int unsigned WordAddrW = AddrWidth - 2
) (
  input logic clk_i,
  input logic issue_i,
  input logic [SolverAddrWidth-1:2] addr_word_i,
  input logic rsp_ready_i,
  input logic hold_ar_i,
  input logic hold_r_i,
  input logic invalidate_i
);

  logic rst_ni;

  logic [WordAddrW-1:0] axi_word_addr;
  logic [DataWidth-1:0] axi_instr;
  logic [WordAddrW-1:0] rsp_word_addr;
  logic [DataWidth-1:0] rsp_instr;

  core_bus_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) core_bus ();
  axi4_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth)
  ) axi ();
  icache_performance_debug_if performance ();

  initial begin
    rst_ni = 1'b0;
    SolverAddr12: assert (SolverAddrWidth == 12);
    BlockAligned: assert ((BlockBytes % 4) == 0);
    BurstLine: assert (BlockBytes > DataWidth / 8);
  end
  always_ff @(posedge clk_i) rst_ni <= 1'b1;

  fv_cpu_fetch #(
    .AddrWidth(AddrWidth),
    .SolverAddrWidth(SolverAddrWidth)
  ) u_cpu (
    .clk_i,
    .rst_ni,
    .issue_i,
    .addr_word_i,
    .rsp_ready_i,
    .core_bus
  );

  fv_scoreboard #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) u_scoreboard (
    .clk_i,
    .rst_ni,
    .invalidate_i,
    .rsp_instr_i(rsp_instr),
    .core_bus,
    .performance,
    .rsp_word_addr_o(rsp_word_addr)
  );

  fv_imem #(
    .AddrWidth(AddrWidth),
    .SolverAddrWidth(SolverAddrWidth)
  ) u_imem (
    .clk_i,
    .rst_ni,
    .invalidate_i,
    .axi_word_addr_i(axi_word_addr),
    .axi_instr_o(axi_instr),
    .rsp_word_addr_i(rsp_word_addr),
    .rsp_instr_o(rsp_instr)
  );

  fv_axi_rom #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth),
    .AxiId(AxiId)
  ) u_axi (
    .clk_i,
    .rst_ni,
    .hold_ar_i,
    .hold_r_i,
    .rdata_i(axi_instr),
    .word_addr_o(axi_word_addr),
    .axi
  );

  icache #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth),
    .AxiId(AxiId),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .ReplacementPolicy(ReplacementPolicy)
  ) u_dut (
    .clk_i,
    .rst_ni,
    .invalidate_i,
    .core_bus,
    .axi,
    .performance
  );

endmodule
