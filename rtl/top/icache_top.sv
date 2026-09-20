// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// I-cache 引脚展开顶层，可直接嵌入不使用 SystemVerilog interface 端口的设计。
//
// 内部实例化 CoreBus 与 AXI4 interface，接到 `icache`；对外将 CPU 侧 CoreBus
// 从设备和存储器侧 AXI4 主设备展开为标量端口。参数默认与 `icache` 相同。
module icache_top
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
  localparam int unsigned StrbWidth = DataWidth / 8
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,

  // CPU 侧 CoreBus 从设备
  input logic req_valid_i,
  output logic req_ready_o,
  input logic [AddrWidth-1:0] req_addr_i,
  input logic req_write_i,
  input logic [1:0] req_size_i,
  input logic [DataWidth-1:0] req_wdata_i,
  input logic [StrbWidth-1:0] req_wstrb_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output logic [DataWidth-1:0] rsp_rdata_o,
  output logic rsp_error_o,

  // 存储器侧 AXI4 主设备
  input logic axi_awready_i,
  output logic axi_awvalid_o,
  output logic [AddrWidth-1:0] axi_awaddr_o,
  output logic [IdWidth-1:0] axi_awid_o,
  output logic [7:0] axi_awlen_o,
  output logic [2:0] axi_awsize_o,
  output logic [1:0] axi_awburst_o,
  input logic axi_wready_i,
  output logic axi_wvalid_o,
  output logic [DataWidth-1:0] axi_wdata_o,
  output logic [StrbWidth-1:0] axi_wstrb_o,
  output logic axi_wlast_o,
  output logic axi_bready_o,
  input logic axi_bvalid_i,
  input logic [1:0] axi_bresp_i,
  input logic [IdWidth-1:0] axi_bid_i,
  input logic axi_arready_i,
  output logic axi_arvalid_o,
  output logic [AddrWidth-1:0] axi_araddr_o,
  output logic [IdWidth-1:0] axi_arid_o,
  output logic [7:0] axi_arlen_o,
  output logic [2:0] axi_arsize_o,
  output logic [1:0] axi_arburst_o,
  output logic axi_rready_o,
  input logic axi_rvalid_i,
  input logic [1:0] axi_rresp_i,
  input logic [DataWidth-1:0] axi_rdata_i,
  input logic axi_rlast_i,
  input logic [IdWidth-1:0] axi_rid_i
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

  ////////////////////////
  // CoreBus 接口适配 //
  ////////////////////////

  assign core_bus.req_valid = req_valid_i;
  assign core_bus.req_payload.addr = req_addr_i;
  assign core_bus.req_payload.write = req_write_i;
  assign core_bus.req_payload.size = core_bus_size_e'(req_size_i);
  assign core_bus.req_payload.wdata = req_wdata_i;
  assign core_bus.req_payload.wstrb = req_wstrb_i;
  assign core_bus.rsp_ready = rsp_ready_i;
  assign req_ready_o = core_bus.req_ready;
  assign rsp_valid_o = core_bus.rsp_valid;
  assign rsp_rdata_o = core_bus.rsp_payload.rdata;
  assign rsp_error_o = core_bus.rsp_payload.error;

  ////////////////////////
  // AXI4 主接口适配 //
  ////////////////////////

  assign axi_awvalid_o = axi.awvalid;
  assign axi_awaddr_o = axi.aw_payload.addr;
  assign axi_awid_o = axi.aw_payload.id;
  assign axi_awlen_o = axi.aw_payload.len;
  assign axi_awsize_o = axi.aw_payload.size;
  assign axi_awburst_o = axi.aw_payload.burst;
  assign axi_wvalid_o = axi.wvalid;
  assign axi_wdata_o = axi.w_payload.data;
  assign axi_wstrb_o = axi.w_payload.strb;
  assign axi_wlast_o = axi.w_payload.last;
  assign axi_bready_o = axi.bready;
  assign axi_arvalid_o = axi.arvalid;
  assign axi_araddr_o = axi.ar_payload.addr;
  assign axi_arid_o = axi.ar_payload.id;
  assign axi_arlen_o = axi.ar_payload.len;
  assign axi_arsize_o = axi.ar_payload.size;
  assign axi_arburst_o = axi.ar_payload.burst;
  assign axi_rready_o = axi.rready;

  assign axi.awready = axi_awready_i;
  assign axi.wready = axi_wready_i;
  assign axi.bvalid = axi_bvalid_i;
  assign axi.b_payload.resp = axi_bresp_i;
  assign axi.b_payload.id = axi_bid_i;
  assign axi.arready = axi_arready_i;
  assign axi.rvalid = axi_rvalid_i;
  assign axi.r_payload.resp = axi_rresp_i;
  assign axi.r_payload.data = axi_rdata_i;
  assign axi.r_payload.last = axi_rlast_i;
  assign axi.r_payload.id = axi_rid_i;

  icache #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth),
    .AxiId(AxiId),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .ReplacementPolicy(ReplacementPolicy)
  ) u_icache (
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
