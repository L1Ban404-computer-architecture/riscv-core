// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 参数化超小型 I-cache 顶层。
//
// 默认几何由 icache_pkg 给出。控制器只允许一笔 miss 在途；命中由寄存器阵列组合
// 返回，miss 的 AXI R beat 直接写入阵列，不保存请求副本或完整缓存行。
//
// invalidate_i 是电平请求：先排空已经对外展示或已经握手的事务，再清除全部 valid；
// 信号保持为高时持续阻止新请求进入。
`include "common/assertions.svh"

module icache
  import riscv_bus_pkg::*;
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = ICACHE_AXI_ID,
  parameter int unsigned BlockBytes = ICacheBlockBytes,
  parameter int unsigned SetCount = ICacheSetCount,
  parameter int unsigned WayCount = ICacheWayCount,
  parameter icache_replacement_policy_e ReplacementPolicy = ICacheReplacementPolicy,
  localparam int unsigned BlockOffsetW = $clog2(BlockBytes),
  localparam int unsigned SetIndexBits = $clog2(SetCount),
  localparam int unsigned TagW = AddrWidth - BlockOffsetW - SetIndexBits
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,

  // 指令请求与下级存储访问
  core_bus_if.slave core_bus,
  axi4_if.master axi
`ifndef SYNTHESIS
  ,
  icache_performance_debug_if.producer performance
`endif
);

  //////////////////
  // 内部语义接口 //
  //////////////////

  icache_lookup_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .WayCount(WayCount)
  ) lookup ();
  icache_refill_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount)
  ) refill ();

  // 控制器确认在途事务全部完成后，通过该使能通知阵列清除有效位。
  logic invalidate_apply;

  //////////////////////
  // 控制器与寄存器阵列 //
  //////////////////////

  icache_control #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth),
    .AxiId(AxiId),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount)
  ) u_control (
    .clk_i,
    .rst_ni,
    .core_bus,
    .axi,
    .lookup,
    .refill,
    .invalidate_i,
    .invalidate_apply_o(invalidate_apply)
  );

  icache_array #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .ReplacementPolicy(ReplacementPolicy)
  ) u_array (
    .clk_i,
    .rst_ni,
    .lookup,
    .refill,
    .invalidate_apply_i(invalidate_apply)
  );

`ifndef SYNTHESIS
  icache_performance_stats u_performance_stats (
    .clk_i,
    .rst_ni,
    .req_valid_i(core_bus.req_valid),
    .req_ready_i(core_bus.req_ready),
    .rsp_valid_i(core_bus.rsp_valid),
    .rsp_ready_i(core_bus.rsp_ready),
    .performance
  );
`endif

  ////////////////////
  // 参数与接口断言 //
  ////////////////////

  `ASSERT_INIT(ICacheCoreBusAddrWidth, $bits(core_bus.req_payload.addr) == AddrWidth)
  `ASSERT_INIT(ICacheCoreBusDataWidth, $bits(core_bus.req_payload.wdata) == DataWidth)
  `ASSERT_INIT(ICacheAxiAddrWidth, $bits(axi.ar_payload.addr) == AddrWidth)
  `ASSERT_INIT(ICacheAxiDataWidth, $bits(axi.r_payload.data) == DataWidth)
  `ASSERT_INIT(ICacheAxiIdWidth, $bits(axi.ar_payload.id) == IdWidth)
  `ASSERT_INIT(ICacheTagWidthValid, TagW > 0)

endmodule
