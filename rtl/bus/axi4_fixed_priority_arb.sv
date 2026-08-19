// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// I-cache 与数据侧 CoreBus AXI4 固定优先级仲裁器。
//
// 数据侧拥有 AR 固定优先级和全部写通道。读响应按固定 AXI ID 直接分路，不设置
// 响应 FIFO、在途计数或数据寄存器；仅在 AR 反压时保存一位授权来源。
`include "common/assertions.svh"

module axi4_fixed_priority_arb
  import riscv_bus_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned ICacheAxiId = ICACHE_AXI_ID,
  parameter int unsigned MemAxiId = MEM_AXI_ID
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 两路 AXI4 请求与核心外部接口
  axi4_if.slave if_axi,
  axi4_if.slave mem_axi,
  axi4_if.master core_axi
);

  ////////////////////////
  // AR 选择与所有权保持 //
  ////////////////////////

  logic ar_locked_q;
  logic ar_owner_mem_q;
  logic select_mem;
  logic core_ar_fire;

  // 选中的 AR 源在外部反压时必须保持不变；锁存的所有权阻止后来到达的数据请求
  // 改变已经展示给外部总线的请求源。
  assign select_mem = ar_locked_q ? ar_owner_mem_q : mem_axi.arvalid;
  assign core_ar_fire = core_axi.arvalid && core_axi.arready;

  //////////////////////
  // AXI 通道组合仲裁 //
  //////////////////////

  always_comb begin
    core_axi.awvalid = mem_axi.awvalid;
    core_axi.aw_payload = mem_axi.aw_payload;
    core_axi.wvalid = mem_axi.wvalid;
    core_axi.w_payload = mem_axi.w_payload;
    core_axi.bready = mem_axi.bready;
    core_axi.arvalid = 1'b0;
    core_axi.ar_payload = '0;
    core_axi.rready = 1'b0;

    if_axi.awready = 1'b0;
    if_axi.wready = 1'b0;
    if_axi.bvalid = 1'b0;
    if_axi.b_payload = '0;
    if_axi.arready = 1'b0;
    if_axi.rvalid = 1'b0;
    if_axi.r_payload = '0;

    mem_axi.awready = core_axi.awready;
    mem_axi.wready = core_axi.wready;
    mem_axi.bvalid = core_axi.bvalid;
    mem_axi.b_payload = core_axi.b_payload;
    mem_axi.arready = 1'b0;
    mem_axi.rvalid = 1'b0;
    mem_axi.r_payload = '0;

    if (select_mem) begin
      core_axi.arvalid = mem_axi.arvalid;
      core_axi.ar_payload = mem_axi.ar_payload;
      mem_axi.arready = core_axi.arready;
    end else begin
      core_axi.arvalid = if_axi.arvalid;
      core_axi.ar_payload = if_axi.ar_payload;
      if_axi.arready = core_axi.arready;
    end

    // 外部 R 通道按 ID 直接选择唯一目标；RREADY 从目标侧直通，不设置响应缓存。
    if (core_axi.rvalid) begin
      unique case (core_axi.r_payload.id)
        IdWidth'(ICacheAxiId): begin
          if_axi.rvalid = 1'b1;
          if_axi.r_payload = core_axi.r_payload;
          core_axi.rready = if_axi.rready;
        end
        IdWidth'(MemAxiId): begin
          mem_axi.rvalid = 1'b1;
          mem_axi.r_payload = core_axi.r_payload;
          core_axi.rready = mem_axi.rready;
        end
        default: ;
      endcase
    end
  end

  ////////////////////
  // AR 所有权状态更新 //
  ////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_locked_q <= 1'b0;
      ar_owner_mem_q <= 1'b0;
    end else if (ar_locked_q) begin
      if (core_ar_fire) ar_locked_q <= 1'b0;
    end else if (core_axi.arvalid && !core_axi.arready) begin
      ar_locked_q <= 1'b1;
      ar_owner_mem_q <= select_mem;
    end
  end

  //////////////////
  // 协议与参数断言 //
  //////////////////

  `ASSERT_STABLE(AxiArbCoreArStable, core_axi.arvalid, core_axi.arready,
                 core_axi.ar_payload, '0, clk_i, !rst_ni,
                 "AR source and payload must remain stable while the slave backpressures.")
  `ASSERT(AxiArbCoreBusReadPriority,
          !ar_locked_q && mem_axi.arvalid && if_axi.arvalid |->
              core_axi.arvalid && (core_axi.ar_payload == mem_axi.ar_payload),
          clk_i, !rst_ni, "The data-side read request has fixed priority.")
  `ASSERT(AxiArbICacheNeverWrites,
          !if_axi.awvalid && !if_axi.wvalid && !if_axi.bready, clk_i, !rst_ni,
          "The connected I-cache must not issue AXI writes.")
  `ASSERT(AxiArbReadIdKnown,
          core_axi.rvalid |-> (core_axi.r_payload.id == IdWidth'(ICacheAxiId)) ||
              (core_axi.r_payload.id == IdWidth'(MemAxiId)),
          clk_i, !rst_ni, "AXI read response ID must identify a connected requester.")
  `ASSERT(AxiArbWriteIdKnown,
          core_axi.bvalid |-> (core_axi.b_payload.id == IdWidth'(MemAxiId)),
          clk_i, !rst_ni, "Only the data-side adapter may receive AXI write responses.")

  `ASSERT_INIT(AxiArbAddressAndIdWidthsValid, AddrWidth > 0 && IdWidth > 0)
  `ASSERT_INIT(AxiArbDataWidthValid,
               DataWidth >= 8 && (DataWidth % 8) == 0 && (DataWidth & (DataWidth - 1)) == 0)
  `ASSERT_INIT(AxiArbICacheIdFits, (ICacheAxiId >> IdWidth) == 0)
  `ASSERT_INIT(AxiArbMemIdFits, (MemAxiId >> IdWidth) == 0)
  `ASSERT_INIT(AxiArbDistinctIds, ICacheAxiId != MemAxiId)
  `ASSERT_INIT(AxiArbAddressWidthMatches, $bits(core_axi.aw_payload.addr) == AddrWidth)
  `ASSERT_INIT(AxiArbDataWidthMatches, $bits(core_axi.w_payload.data) == DataWidth)
  `ASSERT_INIT(AxiArbIdWidthMatches, $bits(core_axi.aw_payload.id) == IdWidth)

endmodule
