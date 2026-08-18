// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 超小型 I-cache 综合展开外壳。
//
// 将 CoreBus/AXI4 interface 展开为普通端口，供综合工具检查参数化实现；正式集成
// 仍直接实例化带 interface 端口的 icache。write_activity_o 用于保留并观察写通道。
module icache_synth_top #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,

  // 展开的只读 CoreBus
  input logic req_valid_i,
  input logic [AddrWidth-1:0] req_addr_i,
  output logic req_ready_o,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output logic [DataWidth-1:0] rsp_data_o,
  output logic rsp_error_o,

  // 展开的 AXI4 AR/R 通道
  output logic arvalid_o,
  input logic arready_i,
  output logic [AddrWidth-1:0] araddr_o,
  output logic [IdWidth-1:0] arid_o,
  output logic [7:0] arlen_o,
  output logic [2:0] arsize_o,
  output logic [1:0] arburst_o,
  input logic rvalid_i,
  output logic rready_o,
  input logic [1:0] rresp_i,
  input logic [DataWidth-1:0] rdata_i,
  input logic rlast_i,
  input logic [IdWidth-1:0] rid_i,

  // AXI4 写通道活动汇聚，正确实现中应恒为零
  output logic write_activity_o
);

  //////////////////////////
  // 参数化接口与信号映射 //
  //////////////////////////

  core_bus_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) core_bus ();
  axi4_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth)
  ) axi ();

  // CoreBus 仅构造 word read，写相关 payload 固定为零；地址对齐由上层输入保证。
  assign core_bus.req_payload.addr = req_addr_i;
  assign core_bus.req_payload.write = 1'b0;
  assign core_bus.req_payload.size = riscv_bus_pkg::CORE_BUS_SIZE_WORD;
  assign core_bus.req_payload.wdata = '0;
  assign core_bus.req_payload.wstrb = '0;
  assign core_bus.req_valid = req_valid_i;
  assign core_bus.rsp_ready = rsp_ready_i;
  assign req_ready_o = core_bus.req_ready;
  assign rsp_valid_o = core_bus.rsp_valid;
  assign rsp_data_o = core_bus.rsp_payload.rdata;
  assign rsp_error_o = core_bus.rsp_payload.error;

  // AXI 从侧写通道空闲；AR/R 普通信号与 interface 字段一一映射。
  assign axi.awready = 1'b0;
  assign axi.wready = 1'b0;
  assign axi.bvalid = 1'b0;
  assign axi.b_payload = '0;
  assign axi.arready = arready_i;
  assign axi.rvalid = rvalid_i;
  assign axi.r_payload.resp = rresp_i;
  assign axi.r_payload.data = rdata_i;
  assign axi.r_payload.last = rlast_i;
  assign axi.r_payload.id = rid_i;
  assign arvalid_o = axi.arvalid;
  assign araddr_o = axi.ar_payload.addr;
  assign arid_o = axi.ar_payload.id;
  assign arlen_o = axi.ar_payload.len;
  assign arsize_o = axi.ar_payload.size;
  assign arburst_o = axi.ar_payload.burst;
  assign rready_o = axi.rready;
  assign write_activity_o = ^{axi.awvalid, axi.aw_payload, axi.wvalid, axi.w_payload, axi.bready};

  //////////////////
  // 被测 I-cache 实例 //
  //////////////////

  icache #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth)
  ) u_icache (
    .clk_i,
    .rst_ni,
    .invalidate_i,
    .core_bus,
    .axi
  );

endmodule
