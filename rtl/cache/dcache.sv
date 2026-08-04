// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Placeholder data cache.  It implements one outstanding CoreBus transaction
// and converts it directly to a single-beat AXI4 read or write.
`include "common/assertions.svh"

import riscv_core_pkg::*;

module dcache (
  input logic clk_i,
  input logic rst_ni,

  input  core_bus_req_t  core_req_i,
  output core_bus_resp_t core_resp_o,

  output axi4_req_t  axi_req_o,
  input  axi4_resp_t axi_resp_i
);

  typedef enum logic [1:0] {
    StateIdle,
    StateReadResponse,
    StateWriteResponse
  } state_e;

  state_e state_q;
  logic aw_sent_q;
  logic w_sent_q;
  logic read_request;
  logic write_request;
  logic aw_fire;
  logic w_fire;
  logic write_request_complete;
  logic active_read_response;
  logic active_write_response;
  logic request_fire;
  logic response_fire;

  assign read_request = (state_q == StateIdle) && !aw_sent_q && !w_sent_q &&
      core_req_i.req_valid && !core_req_i.write;
  assign write_request = (state_q == StateIdle) && core_req_i.req_valid &&
      core_req_i.write;

  assign aw_fire = write_request && !aw_sent_q && axi_resp_i.awready;
  assign w_fire = write_request && !w_sent_q && axi_resp_i.wready;
  assign write_request_complete = write_request && (aw_sent_q || aw_fire) &&
      (w_sent_q || w_fire);

  // The current request is included so a zero-latency AXI responder can also
  // complete the CoreBus response in the request handshake cycle.
  assign active_read_response = (state_q == StateReadResponse) ||
      (read_request && axi_resp_i.arready);
  assign active_write_response = (state_q == StateWriteResponse) ||
      write_request_complete;

  always_comb begin
    axi_req_o = '0;

    axi_req_o.arvalid = read_request;
    axi_req_o.araddr = core_req_i.addr;
    axi_req_o.arid = DCACHE_AXI_ID;
    axi_req_o.arlen = 8'd0;
    axi_req_o.arsize = {1'b0, core_req_i.size};
    axi_req_o.arburst = AXI4_BURST_INCR;
    axi_req_o.rready = active_read_response && core_req_i.rsp_ready;

    axi_req_o.awvalid = write_request && !aw_sent_q;
    axi_req_o.awaddr = core_req_i.addr;
    axi_req_o.awid = DCACHE_AXI_ID;
    axi_req_o.awlen = 8'd0;
    axi_req_o.awsize = {1'b0, core_req_i.size};
    axi_req_o.awburst = AXI4_BURST_INCR;

    axi_req_o.wvalid = write_request && !w_sent_q;
    axi_req_o.wdata = core_req_i.wdata;
    axi_req_o.wstrb = core_req_i.wstrb;
    axi_req_o.wlast = 1'b1;
    axi_req_o.bready = active_write_response && core_req_i.rsp_ready;

    core_resp_o = '0;
    if (state_q == StateIdle) begin
      core_resp_o.req_ready = core_req_i.write ? write_request_complete :
          (!aw_sent_q && !w_sent_q && axi_resp_i.arready);
    end

    if (active_read_response) begin
      core_resp_o.rdata = axi_resp_i.rdata;
      core_resp_o.error = (axi_resp_i.rresp != AXI4_RESP_OKAY) ||
          !axi_resp_i.rlast || (axi_resp_i.rid != DCACHE_AXI_ID);
      core_resp_o.rsp_valid = axi_resp_i.rvalid;
    end else if (active_write_response) begin
      core_resp_o.rdata = '0;
      core_resp_o.error = (axi_resp_i.bresp != AXI4_RESP_OKAY) ||
          (axi_resp_i.bid != DCACHE_AXI_ID);
      core_resp_o.rsp_valid = axi_resp_i.bvalid;
    end
  end

  assign request_fire = core_req_i.req_valid && core_resp_o.req_ready;
  assign response_fire = core_resp_o.rsp_valid && core_req_i.rsp_ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StateIdle;
      aw_sent_q <= 1'b0;
      w_sent_q <= 1'b0;
    end else begin
      unique case (state_q)
        StateIdle: begin
          if (write_request) begin
            if (request_fire) begin
              aw_sent_q <= 1'b0;
              w_sent_q <= 1'b0;
              if (!response_fire) state_q <= StateWriteResponse;
            end else begin
              if (aw_fire) aw_sent_q <= 1'b1;
              if (w_fire) w_sent_q <= 1'b1;
            end
          end else if (request_fire && !response_fire) begin
            state_q <= StateReadResponse;
          end
        end

        StateReadResponse: begin
          if (response_fire) state_q <= StateIdle;
        end

        StateWriteResponse: begin
          if (response_fire) state_q <= StateIdle;
        end

        default: begin
          state_q <= StateIdle;
          aw_sent_q <= 1'b0;
          w_sent_q <= 1'b0;
        end
      endcase
    end
  end

  `ASSERT(DCacheSingleBeatResponse,
          axi_resp_i.rvalid |-> axi_resp_i.rlast,
          clk_i, !rst_ni, "DCache only supports single-beat AXI reads.")

endmodule
