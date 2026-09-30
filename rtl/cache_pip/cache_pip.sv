// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 流水线式 I-cache。
//
// 阵列完成组合读并把结果打入 lookup。组合响应级命中时直接回应 CPU，缺失时把
// 请求保持给缺失处理器；处理器取回整行后，在写回提交的下一拍回应 CPU。请求与
// 响应分属 core_bus_if 的 req_slave 和 rsp_source。
//
// 失效控制器只锁存 invalidate 并在空闲时清除有效位。已经进入 lookup 的请求照常
// 回应，不因失效改写其数据。
`include "common/assertions.svh"

module cache_pip
  import riscv_bus_pkg::*;
  import icache_pip_pkg::*;
#(
  parameter int unsigned AddrWidth = ICachePipAddrWidth,
  parameter int unsigned DataWidth = ICachePipDataWidth,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = ICACHE_AXI_ID,
  parameter int unsigned BlockBytes = ICachePipBlockBytes,
  parameter int unsigned SetCount = ICachePipSetCount,
  parameter int unsigned WayCount = ICachePipWayCount,
  parameter icache_pip_replacement_policy_e ReplacementPolicy = ICachePipReplacementPolicy
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,

  // 指令请求与下级存储访问。失效逻辑可以挡住新请求；响应级直接驱动回应。
  core_bus_if core_bus,
  axi4_if.master axi
`ifndef SYNTHESIS
  ,
  // 性能计数接口复用阻塞式 I-cache 的 debug interface。
  icache_performance_debug_if.producer performance
`endif
);

  //////////////////
  // 内部语义接口 //
  //////////////////

  cache_lookup_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) lookup ();
  cache_miss_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) miss ();
  cache_refill_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) refill ();

  // 失效只消费 lookup/refill 的占用标志，并门控尚未握手的请求。
  logic block_req;
  logic invalidate_apply;

  cache_invalidate u_invalidate (
    .clk_i,
    .rst_ni,
    .invalidate_i,
    .lookup_valid_i(lookup.valid),
    .refill_addr_valid_i(refill.addr_valid),
    .block_req_o(block_req),
    .invalidate_apply_o(invalidate_apply)
  );

  // 阵列看到的是放行后的请求。外部 ready 在 block 时为低，已握手的查询留在 lookup。
  core_bus_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) array_req ();

  assign array_req.req_valid = core_bus.req_valid && !block_req;
  assign array_req.req_payload = core_bus.req_payload;
  assign core_bus.req_ready = array_req.req_ready && !block_req;

`ifndef SYNTHESIS
  cache_pip_performance_stats u_performance_stats (
    .clk_i,
    .rst_ni,
    .core_bus,
    .lookup,
    .refill,
    .performance
  );
`endif

  //////////////////////
  // 阵列、响应与缺失 //
  //////////////////////

  cache_array #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .ReplacementPolicy(ReplacementPolicy)
  ) u_array (
    .clk_i,
    .rst_ni,
    .invalidate_apply_i(invalidate_apply),
    .core_bus(array_req),
    .lookup,
    .refill
  );

  cache_rsp #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) u_rsp (
    .clk_i,
    .rst_ni,
    .lookup,
    .miss,
    .core_bus
  );

  cache_miss #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth),
    .AxiId(AxiId),
    .BlockBytes(BlockBytes)
  ) u_miss (
    .clk_i,
    .rst_ni,
    .miss,
    .refill,
    .axi
  );

  `ASSERT(CachePipInvalidateBlocksRequest, block_req |-> !core_bus.req_ready, clk_i, !rst_ni,
          "A new request must not be accepted while invalidate is blocking admission.")

  `ASSERT_INIT(CachePipCoreBusAddrWidth, $bits(core_bus.req_payload.addr) == AddrWidth)
  `ASSERT_INIT(CachePipCoreBusDataWidth, $bits(core_bus.rsp_payload.rdata) == DataWidth)
  `ASSERT_INIT(CachePipAxiAddrWidth, $bits(axi.ar_payload.addr) == AddrWidth)
  `ASSERT_INIT(CachePipAxiDataWidth, $bits(axi.r_payload.data) == DataWidth)
  `ASSERT_INIT(CachePipAxiIdWidth, $bits(axi.ar_payload.id) == IdWidth)

endmodule
