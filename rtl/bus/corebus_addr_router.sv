// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// CoreBus 地址路由器。
//
// 按掩码匹配地址，将单个 CoreBus 主设备路由到目标设备或默认从设备。
// 最多允许一笔未完成事务；请求被接受后必须锁存目标选择直至响应完成；
// 请求握手当拍允许从设备返回零延迟响应。

module corebus_addr_router
  import riscv_bus_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
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

  // 路由选择与事务状态

  logic busy_q;
  logic owner_device_q;
  logic request_device;
  logic active_device;

  assign request_device = (master_bus.req_payload.addr & DeviceMask) == (DeviceBase & DeviceMask);
  assign active_device = busy_q ? owner_device_q : request_device;

  // 请求与响应路由

  assign device_bus.req_payload = master_bus.req_payload;
  assign fallback_bus.req_payload = master_bus.req_payload;
  assign device_bus.req_valid = master_bus.req_valid && !busy_q && request_device;
  assign fallback_bus.req_valid = master_bus.req_valid && !busy_q && !request_device;
  assign master_bus.req_ready = !busy_q &&
      (request_device ? device_bus.req_ready : fallback_bus.req_ready);

  // 已接受事务使用锁存的目标；同拍响应使用当前请求目标。
  assign device_bus.rsp_ready = master_bus.rsp_ready && active_device;
  assign fallback_bus.rsp_ready = master_bus.rsp_ready && !active_device;
  always_comb begin
    master_bus.rsp_valid = 1'b0;
    master_bus.rsp_payload = '0;
    if (busy_q || master_bus.req_valid) begin
      master_bus.rsp_valid = active_device ? device_bus.rsp_valid : fallback_bus.rsp_valid;
      master_bus.rsp_payload = active_device ? device_bus.rsp_payload : fallback_bus.rsp_payload;
    end
  end

  // 目标所有权寄存

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      busy_q <= 1'b0;
      owner_device_q <= 1'b0;
    end else begin
      if (master_bus.rsp_fire) busy_q <= 1'b0;
      else if (master_bus.req_fire) busy_q <= 1'b1;

      if (master_bus.req_fire) owner_device_q <= request_device;
    end
  end

endmodule
