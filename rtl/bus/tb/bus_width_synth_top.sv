// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 总线宽度综合展开外壳。
//
// 以非 RV32 默认宽度实例化地址路由器和 AXI4 汇聚器，供综合工具检查参数传播。
// 所有输入接口保持空闲，activity_o 仅用于保留被检查的组合输出。
module bus_width_synth_top #(
  parameter int unsigned AddrWidth = 40,
  parameter int unsigned DataWidth = 64,
  parameter int unsigned IdWidth = 6
) (
  // 全局控制与活动观测
  input logic clk_i,
  input logic rst_ni,
  output logic activity_o
);

  ////////////////////
  // 参数化总线实例 //
  ////////////////////

  core_bus_if #(.AddrWidth(AddrWidth), .DataWidth(DataWidth)) upstream();
  core_bus_if #(.AddrWidth(AddrWidth), .DataWidth(DataWidth)) device();
  core_bus_if #(.AddrWidth(AddrWidth), .DataWidth(DataWidth)) fallback();
  axi4_if #(.AddrWidth(AddrWidth), .DataWidth(DataWidth), .IdWidth(IdWidth)) icache_axi();
  axi4_if #(.AddrWidth(AddrWidth), .DataWidth(DataWidth), .IdWidth(IdWidth)) dcache_axi();
  axi4_if #(.AddrWidth(AddrWidth), .DataWidth(DataWidth), .IdWidth(IdWidth)) master_axi();

  //////////////////
  // 空闲接口驱动 //
  //////////////////

  assign upstream.addr = '0;
  assign upstream.write = 1'b0;
  assign upstream.size = riscv_bus_pkg::CORE_BUS_SIZE_DWORD;
  assign upstream.wdata = '0;
  assign upstream.wstrb = '0;
  assign upstream.req_valid = 1'b0;
  assign upstream.rsp_ready = 1'b0;
  assign device.req_ready = 1'b0;
  assign device.rdata = '0;
  assign device.error = 1'b0;
  assign device.rsp_valid = 1'b0;
  assign fallback.req_ready = 1'b0;
  assign fallback.rdata = '0;
  assign fallback.error = 1'b0;
  assign fallback.rsp_valid = 1'b0;

  assign icache_axi.awvalid = 1'b0;
  assign icache_axi.awaddr = '0;
  assign icache_axi.awid = '0;
  assign icache_axi.awlen = '0;
  assign icache_axi.awsize = '0;
  assign icache_axi.awburst = '0;
  assign icache_axi.wvalid = 1'b0;
  assign icache_axi.wdata = '0;
  assign icache_axi.wstrb = '0;
  assign icache_axi.wlast = 1'b0;
  assign icache_axi.bready = 1'b0;
  assign icache_axi.arvalid = 1'b0;
  assign icache_axi.araddr = '0;
  assign icache_axi.arid = '0;
  assign icache_axi.arlen = '0;
  assign icache_axi.arsize = '0;
  assign icache_axi.arburst = '0;
  assign icache_axi.rready = 1'b0;

  assign dcache_axi.awvalid = 1'b0;
  assign dcache_axi.awaddr = '0;
  assign dcache_axi.awid = '0;
  assign dcache_axi.awlen = '0;
  assign dcache_axi.awsize = '0;
  assign dcache_axi.awburst = '0;
  assign dcache_axi.wvalid = 1'b0;
  assign dcache_axi.wdata = '0;
  assign dcache_axi.wstrb = '0;
  assign dcache_axi.wlast = 1'b0;
  assign dcache_axi.bready = 1'b0;
  assign dcache_axi.arvalid = 1'b0;
  assign dcache_axi.araddr = '0;
  assign dcache_axi.arid = '0;
  assign dcache_axi.arlen = '0;
  assign dcache_axi.arsize = '0;
  assign dcache_axi.arburst = '0;
  assign dcache_axi.rready = 1'b0;

  assign master_axi.awready = 1'b0;
  assign master_axi.wready = 1'b0;
  assign master_axi.bvalid = 1'b0;
  assign master_axi.bresp = '0;
  assign master_axi.bid = '0;
  assign master_axi.arready = 1'b0;
  assign master_axi.rvalid = 1'b0;
  assign master_axi.rresp = '0;
  assign master_axi.rdata = '0;
  assign master_axi.rlast = 1'b0;
  assign master_axi.rid = '0;

  //////////////////
  // 被测总线模块 //
  //////////////////

  corebus_addr_router #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .DeviceBase(AddrWidth'('h02_0000)),
    .DeviceMask(AddrWidth'('hff_0000))
  ) u_router (
    .clk_i,
    .rst_ni,
    .master_bus(upstream),
    .device_bus(device),
    .fallback_bus(fallback)
  );

  cache_axi4_mux #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth),
    .ICacheAxiId(17),
    .DCacheAxiId(42)
  ) u_mux (
    .clk_i,
    .rst_ni,
    .icache_axi,
    .dcache_axi,
    .master_axi
  );

  //////////////////
  // 综合活动汇聚 //
  //////////////////

  assign activity_o = ^{upstream.req_ready, upstream.rdata,
                        device.req_valid, fallback.req_valid,
                        master_axi.awvalid, master_axi.awaddr,
                        master_axi.awid, master_axi.wvalid,
                        master_axi.wdata, master_axi.wstrb,
                        master_axi.bready, master_axi.arvalid,
                        master_axi.araddr, master_axi.arid,
                        master_axi.rready, icache_axi.rvalid,
                        dcache_axi.rvalid};

endmodule
