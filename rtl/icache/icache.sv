// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 流水线式 I-cache。
//
// 阵列完成组合读并把结果打入 lookup。组合响应级命中时直接回应 CPU，缺失时把
// 请求保持给缺失处理器；处理器取回整行后，在写回提交的下一拍回应 CPU。请求与
// 响应分属 core_bus_if 的 req_slave 和 rsp_source。
//
// 失效控制器在清除期间过滤新请求，并在空闲时清除有效位。已经进入 lookup 的请求照常
// 回应，不因失效改写其数据。

module icache
  import riscv_bus_pkg::*;
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = ICacheAddrWidth,
  parameter int unsigned DataWidth = ICacheDataWidth,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = ICACHE_AXI_ID,
  parameter int unsigned BlockBytes = ICacheBlockBytes,
  parameter int unsigned SetCount = ICacheSetCount,
  parameter int unsigned WayCount = ICacheWayCount,
  parameter icache_replacement_policy_e ReplacementPolicy = ICacheReplacementPolicy
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
  // 仿真期性能计数。
  icache_performance_debug_if.producer performance
`endif
);

  //////////////////
  // 内部语义接口 //
  //////////////////

  icache_lookup_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) lookup ();
  icache_miss_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) miss ();
  icache_refill_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) refill ();

  // 失效模块在清除期间过滤请求，阵列只看到放行后的查询。
  logic invalidate_apply;
  core_bus_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) array_req ();

  icache_invalidate u_invalidate (
    .clk_i,
    .rst_ni,
    .invalidate_i,
    .lookup_valid_i(lookup.valid),
    .refill_addr_valid_i(refill.addr_valid),
    .core_bus(core_bus),
    .array_req(array_req),
    .invalidate_apply_o(invalidate_apply)
  );

`ifndef SYNTHESIS
  icache_performance_stats u_performance_stats (
    .clk_i,
    .rst_ni,
    .core_bus,
    .lookup,
    .performance
  );
`endif

  //////////////////////
  // 阵列、响应与缺失 //
  //////////////////////

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
    .invalidate_apply_i(invalidate_apply),
    .core_bus(array_req),
    .lookup,
    .refill
  );

  icache_rsp u_rsp (
    .lookup,
    .miss,
    .core_bus
  );

  icache_miss #(
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

endmodule
