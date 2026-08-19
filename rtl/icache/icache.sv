// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 参数化超小型 I-cache 顶层。
//
// 默认数据容量为 4 B * 2 组 * 2 路 = 128 bit。控制器只允许一笔 miss 在途；
// 命中由寄存器阵列组合返回，miss 的 AXI R beat 直接写入阵列，不保存请求副本或
// 完整缓存行。
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
  parameter int unsigned BlockBytes = 8,
  parameter int unsigned SetCount = 2,
  parameter int unsigned WayCount = 2,
  parameter icache_replacement_policy_e ReplacementPolicy = ICACHE_REPLACEMENT_ROUND_ROBIN,
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
