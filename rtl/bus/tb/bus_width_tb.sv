// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns / 1ps

// 总线参数化自检 Testbench。
//
// 验证非默认地址、数据和 AXI ID 宽度下的地址路由、反压保持、读仲裁、
// 响应分流和写通道透传。
// 使用 40 位地址、64 位数据和 6 位 ID；任一字段被隐式截断、错误路由或
// 在反压期间改变都会立即终止测试。
module bus_width_tb;
  import riscv_bus_pkg::*;
  localparam int unsigned AddrWidth = 40;
  localparam int unsigned DataWidth = 64;
  localparam int unsigned IdWidth = 6;
  localparam int unsigned ICacheId = 17;
  localparam int unsigned DCacheId = 42;
  localparam logic [AddrWidth-1:0] DeviceBase = 40'hab_0200_0000;
  localparam logic [AddrWidth-1:0] DeviceMask = 40'hff_ffff_0000;

  logic clk_i;
  logic rst_ni;

  ////////////////////
  // 被测接口与模块 //
  ////////////////////

  core_bus_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) upstream ();
  core_bus_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) device ();
  core_bus_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) fallback ();
  axi4_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth)
  ) icache_axi ();
  axi4_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth)
  ) dcache_axi ();
  axi4_if #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth)
  ) master_axi ();

  corebus_addr_router #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .DeviceBase(DeviceBase),
    .DeviceMask(DeviceMask)
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
    .ICacheAxiId(ICacheId),
    .DCacheAxiId(DCacheId)
  ) u_mux (
    .clk_i,
    .rst_ni,
    .icache_axi,
    .dcache_axi,
    .master_axi
  );

  ////////////////////////
  // 时钟与检查辅助任务 //
  ////////////////////////

  always #5 clk_i = ~clk_i;

  task automatic check(input logic condition, input string message);
    if (!condition) $fatal(1, "%s", message);
  endtask

  ////////////////////////
  // 参数化总线测试场景 //
  ////////////////////////

  initial begin
    clk_i = 1'b0;
    rst_ni = 1'b0;

    upstream.req_payload = '0;
    upstream.req_payload.size = CORE_BUS_SIZE_DWORD;
    upstream.req_valid = 1'b0;
    upstream.rsp_ready = 1'b0;
    device.req_ready = 1'b0;
    device.rsp_payload = '0;
    device.rsp_valid = 1'b0;
    fallback.req_ready = 1'b0;
    fallback.rsp_payload = '0;
    fallback.rsp_valid = 1'b0;

    icache_axi.awvalid = 1'b0;
    icache_axi.aw_payload = '0;
    icache_axi.wvalid = 1'b0;
    icache_axi.w_payload = '0;
    icache_axi.bready = 1'b0;
    icache_axi.arvalid = 1'b0;
    icache_axi.ar_payload = '0;
    icache_axi.rready = 1'b0;

    dcache_axi.awvalid = 1'b0;
    dcache_axi.aw_payload = '0;
    dcache_axi.wvalid = 1'b0;
    dcache_axi.w_payload = '0;
    dcache_axi.bready = 1'b0;
    dcache_axi.arvalid = 1'b0;
    dcache_axi.ar_payload = '0;
    dcache_axi.rready = 1'b0;

    master_axi.awready = 1'b0;
    master_axi.wready = 1'b0;
    master_axi.bvalid = 1'b0;
    master_axi.b_payload = '0;
    master_axi.arready = 1'b0;
    master_axi.rvalid = 1'b0;
    master_axi.r_payload = '0;

    check($bits(upstream.req_payload.addr) == 40, "CoreBus address width is not 40 bits.");
    check($bits(upstream.req_payload.wdata) == 64, "CoreBus data width is not 64 bits.");
    check($bits(upstream.req_payload.wstrb) == 8, "CoreBus strobe width is not 8 bits.");
    check($bits(upstream.req_payload) == 115, "CoreBus request payload width is incorrect.");
    check($bits(upstream.rsp_payload) == 65, "CoreBus response payload width is incorrect.");
    check($bits(master_axi.aw_payload.id) == 6, "AXI ID width is not 6 bits.");
    check($bits(master_axi.aw_payload) == 59, "AXI AW payload width is incorrect.");
    check($bits(master_axi.w_payload) == 73, "AXI W payload width is incorrect.");
    check($bits(master_axi.b_payload) == 8, "AXI B payload width is incorrect.");
    check($bits(master_axi.ar_payload) == 59, "AXI AR payload width is incorrect.");
    check($bits(master_axi.r_payload) == 73, "AXI R payload width is incorrect.");

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_ni = 1'b1;

    // 设备选择覆盖 31 位以上的地址位；目标从设备反压期间，全部 64 位请求字段必须保持。
    upstream.req_payload.addr = DeviceBase | 40'h0000_0000_a8;
    upstream.req_payload.write = 1'b1;
    upstream.req_payload.size = CORE_BUS_SIZE_DWORD;
    upstream.req_payload.wdata = 64'hfedc_ba98_7654_3210;
    upstream.req_payload.wstrb = 8'hff;
    upstream.req_valid = 1'b1;
    device.req_ready = 1'b0;
    fallback.req_ready = 1'b1;
    #1;
    check(device.req_valid && !fallback.req_valid,
          "Router did not select the high-address device.");
    check(!upstream.req_ready, "Router did not propagate device backpressure.");
    check(
        device.req_payload.addr == upstream.req_payload.addr &&
            device.req_payload.wdata == upstream.req_payload.wdata &&
            device.req_payload.wstrb == 8'hff && device.req_payload.size == CORE_BUS_SIZE_DWORD,
        "Router truncated the parameterized CoreBus payload.");
    device.req_ready = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    upstream.req_valid = 1'b0;
    device.req_ready = 1'b0;
    device.rsp_payload.rdata = 64'h0123_4567_89ab_cdef;
    device.rsp_valid = 1'b1;
    fallback.rsp_payload.rdata = 64'hdead_dead_dead_dead;
    fallback.rsp_valid = 1'b1;
    #1;
    check(upstream.rsp_valid && upstream.rsp_payload.rdata == device.rsp_payload.rdata,
          "Router response owner was not retained.");
    check(!device.rsp_ready && !fallback.rsp_ready,
          "Router ignored upstream response backpressure.");
    upstream.rsp_ready = 1'b1;
    #1;
    check(device.rsp_ready && !fallback.rsp_ready,
          "Router response ready reached the wrong slave.");
    @(posedge clk_i);
    @(negedge clk_i);
    device.rsp_valid = 1'b0;
    fallback.rsp_valid = 1'b0;
    upstream.rsp_ready = 1'b0;

    upstream.req_payload.addr = 40'hcd_1234_5678;
    upstream.req_payload.write = 1'b0;
    upstream.req_payload.wdata = '0;
    upstream.req_payload.wstrb = '0;
    upstream.req_valid = 1'b1;
    fallback.req_ready = 1'b1;
    #1;
    check(fallback.req_valid && !device.req_valid && upstream.req_ready,
          "Router fallback selection failed.");
    @(posedge clk_i);
    @(negedge clk_i);
    upstream.req_valid = 1'b0;
    fallback.req_ready = 1'b0;
    fallback.rsp_payload.rdata = 64'h8877_6655_4433_2211;
    fallback.rsp_valid = 1'b1;
    upstream.rsp_ready = 1'b1;
    #1;
    check(upstream.rsp_payload.rdata == fallback.rsp_payload.rdata && fallback.rsp_ready,
          "Router fallback response failed.");
    @(posedge clk_i);
    @(negedge clk_i);
    fallback.rsp_valid = 1'b0;
    upstream.rsp_ready = 1'b0;

    // 读地址冲突时 DCache 获胜，并在 AR 反压期间保持选择。随后发送 ICache 请求，
    // 验证两种 6 位 ID 均能正确路由。
    dcache_axi.arvalid = 1'b1;
    dcache_axi.ar_payload.addr = 40'hfe_1234_5678;
    dcache_axi.ar_payload.id = IdWidth'(DCacheId);
    dcache_axi.ar_payload.len = 8'd0;
    dcache_axi.ar_payload.size = 3'd3;
    dcache_axi.ar_payload.burst = AXI4_BURST_INCR;
    icache_axi.arvalid = 1'b1;
    icache_axi.ar_payload.addr = 40'haa_8765_4320;
    icache_axi.ar_payload.id = IdWidth'(ICacheId);
    icache_axi.ar_payload.len = 8'd0;
    icache_axi.ar_payload.size = 3'd3;
    icache_axi.ar_payload.burst = AXI4_BURST_INCR;
    master_axi.arready = 1'b0;
    #1;
    check(
        master_axi.arvalid && master_axi.ar_payload.addr == dcache_axi.ar_payload.addr &&
            master_axi.ar_payload.id == IdWidth'(DCacheId) && !dcache_axi.arready,
        "AXI mux did not preserve the backpressured DCache AR payload.");
    @(posedge clk_i);
    @(negedge clk_i);
    master_axi.arready = 1'b1;
    #1;
    check(dcache_axi.arready && !icache_axi.arready,
          "AXI mux AR ownership changed under backpressure.");
    @(posedge clk_i);
    @(negedge clk_i);
    dcache_axi.arvalid = 1'b0;
    #1;
    check(
        master_axi.arvalid && master_axi.ar_payload.addr == icache_axi.ar_payload.addr &&
            master_axi.ar_payload.id == IdWidth'(ICacheId) && icache_axi.arready,
        "AXI mux did not issue the pending ICache read.");
    @(posedge clk_i);
    @(negedge clk_i);
    icache_axi.arvalid = 1'b0;
    master_axi.arready = 1'b0;

    dcache_axi.rready = 1'b0;
    master_axi.rvalid = 1'b1;
    master_axi.r_payload.resp = AXI4_RESP_OKAY;
    master_axi.r_payload.data = 64'h8000_0000_0000_0042;
    master_axi.r_payload.last = 1'b1;
    master_axi.r_payload.id = IdWidth'(DCacheId);
    #1;
    check(
        master_axi.rready && dcache_axi.rvalid &&
            dcache_axi.r_payload.data == master_axi.r_payload.data && !icache_axi.rvalid,
        "AXI mux DCache response routing failed.");
    @(posedge clk_i);
    @(negedge clk_i);
    master_axi.rvalid = 1'b0;
    master_axi.r_payload.data = '0;
    #1;
    check(dcache_axi.rvalid && dcache_axi.r_payload.data == 64'h8000_0000_0000_0042,
          "AXI mux did not retain a backpressured 64-bit response.");
    dcache_axi.rready = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    dcache_axi.rready = 1'b0;

    icache_axi.rready = 1'b1;
    master_axi.rvalid = 1'b1;
    master_axi.r_payload.data = 64'h1111_2222_3333_4444;
    master_axi.r_payload.last = 1'b1;
    master_axi.r_payload.id = IdWidth'(ICacheId);
    #1;
    check(
        icache_axi.rvalid && icache_axi.r_payload.id == IdWidth'(ICacheId) &&
            icache_axi.r_payload.data == master_axi.r_payload.data && !dcache_axi.rvalid,
        "AXI mux ICache ID routing failed.");
    @(posedge clk_i);
    @(negedge clk_i);
    master_axi.rvalid = 1'b0;
    icache_axi.rready = 1'b0;

    dcache_axi.awvalid = 1'b1;
    dcache_axi.aw_payload.addr = 40'hf1_2345_6780;
    dcache_axi.aw_payload.id = IdWidth'(DCacheId);
    dcache_axi.aw_payload.len = 8'd0;
    dcache_axi.aw_payload.size = 3'd3;
    dcache_axi.aw_payload.burst = AXI4_BURST_INCR;
    dcache_axi.wvalid = 1'b1;
    dcache_axi.w_payload.data = 64'h0123_4567_89ab_cdef;
    dcache_axi.w_payload.strb = 8'hff;
    dcache_axi.w_payload.last = 1'b1;
    master_axi.awready = 1'b0;
    master_axi.wready = 1'b0;
    #1;
    check(
        master_axi.awvalid && master_axi.aw_payload.addr == dcache_axi.aw_payload.addr &&
            master_axi.aw_payload.id == IdWidth'(DCacheId) && !dcache_axi.awready,
        "AXI mux write-address backpressure failed.");
    check(
        master_axi.wvalid && master_axi.w_payload.data == dcache_axi.w_payload.data &&
            master_axi.w_payload.strb == 8'hff && !dcache_axi.wready,
        "AXI mux truncated the 64-bit write payload or strobe.");
    master_axi.awready = 1'b1;
    master_axi.wready = 1'b1;
    #1;
    check(dcache_axi.awready && dcache_axi.wready, "AXI mux write ready propagation failed.");
    @(posedge clk_i);
    @(negedge clk_i);
    dcache_axi.awvalid = 1'b0;
    dcache_axi.wvalid = 1'b0;
    master_axi.awready = 1'b0;
    master_axi.wready = 1'b0;
    dcache_axi.bready = 1'b1;
    master_axi.bvalid = 1'b1;
    master_axi.b_payload.resp = AXI4_RESP_OKAY;
    master_axi.b_payload.id = IdWidth'(DCacheId);
    #1;
    check(dcache_axi.bvalid && dcache_axi.b_payload.id == IdWidth'(DCacheId) && master_axi.bready,
          "AXI mux write response routing failed.");

    $display("bus_width_tb: PASS (AddrWidth=40 DataWidth=64 IdWidth=6)");
    $finish;
  end

endmodule
