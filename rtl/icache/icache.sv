// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 请求经失效控制进入阵列，命中直接回应，miss 启动独立回填。
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
  // 取消此前接受的取指；同拍接受的新请求仍保留，不清除缓存有效位。
  input logic flush_i,
  input logic invalidate_i,

  // CPU 请求与下级存储访问
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
    .core_bus,
    .array_req,
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
    .invalidate_apply_i(invalidate_apply),
    .core_bus(array_req),
    .lookup,
    .refill
  );

  icache_rsp u_rsp (
    .clk_i,
    .rst_ni,
    .flush_i,
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

`ifndef SYNTHESIS
  icache_performance_stats u_performance_stats (
    .clk_i,
    .rst_ni,
    .core_bus,
    .lookup,
    .performance
  );
`endif

endmodule
