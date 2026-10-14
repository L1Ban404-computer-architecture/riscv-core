// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Array 寄存查询结果，响应级返回命中或首拍 miss 数据，WRAP 回填独立继续。
// 失效控制阻塞新查询，待 lookup 和回填排空后清除有效位。

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
    .refill_valid_i(refill.valid),
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
