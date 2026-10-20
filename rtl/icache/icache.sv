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
  output icache_pkg::icache_performance_payload_t performance_o
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

  logic invalidate_pending_q;
  logic invalidate_block;
  logic invalidate_apply;
  core_bus_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) array_req ();

  // 失效当拍停止接收请求；已有查询和回填排空后再清 valid，避免旧回填复活缓存行。
  // pending 保证失效至少延迟一拍，即使收到 invalidate_i 时阵列已经空闲。
  assign invalidate_block = invalidate_i || invalidate_pending_q;
  assign invalidate_apply = invalidate_pending_q && !lookup.valid && !refill.valid;
  assign array_req.req_valid = core_bus.req_valid && !invalidate_block;
  assign array_req.req_payload = core_bus.req_payload;
  assign core_bus.req_ready = array_req.req_ready && !invalidate_block;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) invalidate_pending_q <= 1'b0;
    else invalidate_pending_q <= invalidate_i || (invalidate_pending_q && !invalidate_apply);
  end

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
  ICacheInvalidateApplyWhenIdle: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !invalidate_apply || (!lookup.valid && !refill.valid)));

  icache_debug_if debug_bus ();
  assign debug_bus.bus = '{
    req_valid: core_bus.req_valid, req_ready: core_bus.req_ready,
    rsp_valid: core_bus.rsp_valid, rsp_ready: core_bus.rsp_ready
  };
  assign debug_bus.lookup_valid = lookup.valid;
  assign debug_bus.lookup_fire = lookup.fire;
  assign debug_bus.lookup_hit = lookup.payload.hit;

  icache_performance_stats u_performance_stats (
    .clk_i,
    .rst_ni,
    .debug(debug_bus),
    .performance_o
  );
`endif

endmodule
