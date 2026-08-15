// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// CoreBus 地址路由器。
//
// 按掩码匹配地址，将单个 CoreBus 主设备路由到目标设备或默认从设备。
// 最多允许一笔未完成事务；请求被接受后必须锁存目标选择直至响应完成；
// 请求握手当拍允许从设备返回零延迟响应。
`include "common/assertions.svh"

module corebus_addr_router
  import riscv_bus_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter logic [AddrWidth-1:0] DeviceBase = 32'h0200_0000,
  parameter logic [AddrWidth-1:0] DeviceMask = 32'hffff_0000
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 上游与下游事务
  core_bus_if.slave master_bus,
  core_bus_if.master device_bus,
  core_bus_if.master fallback_bus
);

  ////////////////////////
  // 路由选择与事务状态 //
  ////////////////////////

  logic busy_q;
  logic owner_device_q;
  logic request_device;
  logic active_device;
  logic request_fire;
  logic response_fire;

  assign request_device = (master_bus.req_payload.addr & DeviceMask) ==
      (DeviceBase & DeviceMask);
  assign active_device = busy_q ? owner_device_q : request_device;

  ////////////////////
  // 请求与响应路由 //
  ////////////////////

  always_comb begin
    device_bus.req_payload = master_bus.req_payload;
    fallback_bus.req_payload = master_bus.req_payload;

    // 路由器最多允许一笔未完成事务，与当前精确异常 LSU 的单 outstanding 约束一致。
    device_bus.req_valid = master_bus.req_valid && !busy_q && request_device;
    fallback_bus.req_valid = master_bus.req_valid && !busy_q && !request_device;
    device_bus.rsp_ready = master_bus.rsp_ready && active_device;
    fallback_bus.rsp_ready = master_bus.rsp_ready && !active_device;

    master_bus.req_ready = 1'b0;
    master_bus.rsp_payload = '0;
    master_bus.rsp_valid = 1'b0;
    if (!busy_q) begin
      master_bus.req_ready = request_device ? device_bus.req_ready :
          fallback_bus.req_ready;
    end

    // 接受请求的同拍即按当前地址选择响应源，使 CoreBus 仍支持从设备零延迟响应。
    if (busy_q || master_bus.req_valid) begin
      if (active_device) begin
        master_bus.rsp_payload = device_bus.rsp_payload;
        master_bus.rsp_valid = device_bus.rsp_valid;
      end else begin
        master_bus.rsp_payload = fallback_bus.rsp_payload;
        master_bus.rsp_valid = fallback_bus.rsp_valid;
      end
    end
  end

  assign request_fire = master_bus.req_valid && master_bus.req_ready;
  assign response_fire = master_bus.rsp_valid && master_bus.rsp_ready;

  //////////////
  // 参数断言 //
  //////////////

  `ASSERT_INIT(CoreBusRouterAddrWidthValid, AddrWidth > 0)
  `ASSERT_INIT(CoreBusRouterDataWidthValid,
               DataWidth >= 8 && (DataWidth % 8) == 0 &&
                   (DataWidth & (DataWidth - 1)) == 0)
  `ASSERT_INIT(CoreBusRouterMasterAddrWidth,
               $bits(master_bus.req_payload.addr) == AddrWidth)
  `ASSERT_INIT(CoreBusRouterMasterDataWidth,
               $bits(master_bus.req_payload.wdata) == DataWidth)
  `ASSERT_INIT(CoreBusRouterDeviceAddrWidth,
               $bits(device_bus.req_payload.addr) == AddrWidth)
  `ASSERT_INIT(CoreBusRouterFallbackDataWidth,
               $bits(fallback_bus.req_payload.wdata) == DataWidth)

  ////////////////////
  // 目标所有权寄存 //
  ////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q <= 1'b0;
      owner_device_q <= 1'b0;
    end else begin
      if (response_fire) busy_q <= 1'b0;
      else if (request_fire) busy_q <= 1'b1;

      if (request_fire) owner_device_q <= request_device;
    end
  end

endmodule
