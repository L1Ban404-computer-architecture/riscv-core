// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 供 Verilator 展开 `cache_pip` 的临时顶层。`cache_pip` 的 CoreBus 端口不带
// modport，不能直接作为 lint 顶层；这里把两侧 interface 实例化并接上。
module cache_pip_lint
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
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i
);

  core_bus_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) core_bus ();
  axi4_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth)
  ) axi ();
`ifndef SYNTHESIS
  icache_performance_debug_if performance ();
`endif

  // 外部主设备与从设备在 lint 中保持静默。
  assign core_bus.req_valid = 1'b0;
  assign core_bus.req_payload = '0;
  assign core_bus.rsp_ready = 1'b0;

  assign axi.awready = 1'b0;
  assign axi.wready = 1'b0;
  assign axi.bvalid = 1'b0;
  assign axi.b_payload = '0;
  assign axi.arready = 1'b0;
  assign axi.rvalid = 1'b0;
  assign axi.r_payload = '0;

  cache_pip #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth),
    .AxiId(AxiId),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .ReplacementPolicy(ReplacementPolicy)
  ) u_cache (
    .clk_i,
    .rst_ni,
    .invalidate_i,
    .core_bus,
    .axi
`ifndef SYNTHESIS
    ,
    .performance
`endif
  );

endmodule
