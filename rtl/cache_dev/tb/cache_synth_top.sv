// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Cache 综合展开外壳。
//
// 为不能直接展开悬空 interface 顶层的工具提供完整 Cache 实例和空闲端口驱动。
// 仅用于综合检查；正式集成直接连接 Cache 接口；activity_o 只用于保留输出逻辑。
module cache_synth_top
  import riscv_common_pkg::*;
#(
  parameter int unsigned AddrWidth = XLen,
  parameter int unsigned DataWidth = XLen,
  parameter int unsigned IdWidth = 4
) (
  // 全局控制与活动观测
  input logic clk_i,
  input logic rst_ni,
  output logic activity_o
);

  //////////////////////////
  // 参数化接口与空闲驱动 //
  //////////////////////////

  core_bus_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) core_bus();
  axi4_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth)
  ) axi();

  assign core_bus.addr = '0;
  assign core_bus.write = 1'b0;
  assign core_bus.size = riscv_bus_pkg::CORE_BUS_SIZE_WORD;
  assign core_bus.wdata = '0;
  assign core_bus.wstrb = '0;
  assign core_bus.req_valid = 1'b0;
  assign core_bus.rsp_ready = 1'b0;

  assign axi.awready = 1'b0;
  assign axi.wready = 1'b0;
  assign axi.bvalid = 1'b0;
  assign axi.bresp = '0;
  assign axi.bid = '0;
  assign axi.arready = 1'b0;
  assign axi.rvalid = 1'b0;
  assign axi.rresp = '0;
  assign axi.rdata = '0;
  assign axi.rlast = 1'b0;
  assign axi.rid = '0;

  //////////////////////////
  // Cache 实例与活动汇聚 //
  //////////////////////////

  cache #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth)
  ) u_cache (
    .clk_i,
    .rst_ni,
    .core_bus,
    .axi
  );

  assign activity_o = ^{core_bus.req_ready, core_bus.rdata, core_bus.error,
                        core_bus.rsp_valid, axi.awvalid, axi.awaddr,
                        axi.awid, axi.wvalid, axi.wdata, axi.wstrb,
                        axi.bready, axi.arvalid, axi.araddr, axi.arid,
                        axi.rready};

endmodule
