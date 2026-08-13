// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Route one blocking CoreBus master to an address-selected device or to a
// fallback slave.  The selected target is remembered until its response is
// accepted, so response routing does not depend on a later request address.
module corebus_addr_router
  import riscv_bus_pkg::*;
#(
  parameter logic [31:0] DeviceBase = 32'h0200_0000,
  parameter logic [31:0] DeviceMask = 32'hffff_0000
) (
  input logic clk_i,
  input logic rst_ni,

  input  core_bus_req_t  master_req_i,
  output core_bus_resp_t master_resp_o,

  output core_bus_req_t  device_req_o,
  input  core_bus_resp_t device_resp_i,

  output core_bus_req_t  fallback_req_o,
  input  core_bus_resp_t fallback_resp_i
);

  logic busy_q;
  logic owner_device_q;
  logic request_device;
  logic active_device;
  logic request_fire;
  logic response_fire;

  assign request_device = (master_req_i.addr & DeviceMask) ==
      (DeviceBase & DeviceMask);
  assign active_device = busy_q ? owner_device_q : request_device;

  always_comb begin
    device_req_o = master_req_i;
    fallback_req_o = master_req_i;

    // Only one transaction may be outstanding through this router.  This is
    // the contract used by the current precise-exception LSU.
    device_req_o.req_valid = master_req_i.req_valid && !busy_q && request_device;
    fallback_req_o.req_valid = master_req_i.req_valid && !busy_q && !request_device;
    device_req_o.rsp_ready = master_req_i.rsp_ready && active_device;
    fallback_req_o.rsp_ready = master_req_i.rsp_ready && !active_device;

    master_resp_o = '0;
    if (!busy_q) begin
      master_resp_o.req_ready = request_device ? device_resp_i.req_ready :
          fallback_resp_i.req_ready;
    end

    // Selecting the response while a request is being accepted also preserves
    // the CoreBus allowance for a zero-latency slave response.
    if (busy_q || master_req_i.req_valid) begin
      if (active_device) begin
        master_resp_o.rdata = device_resp_i.rdata;
        master_resp_o.error = device_resp_i.error;
        master_resp_o.rsp_valid = device_resp_i.rsp_valid;
      end else begin
        master_resp_o.rdata = fallback_resp_i.rdata;
        master_resp_o.error = fallback_resp_i.error;
        master_resp_o.rsp_valid = fallback_resp_i.rsp_valid;
      end
    end
  end

  assign request_fire = master_req_i.req_valid && master_resp_o.req_ready;
  assign response_fire = master_resp_o.rsp_valid && master_req_i.rsp_ready;

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
