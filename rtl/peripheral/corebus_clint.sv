// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Minimal Core Local Interruptor for the current interrupt-free core.  Only
// the read-only 64-bit mtime register is implemented; it advances once per
// clock cycle.  On the 32-bit CoreBus, MtimeAddr and MtimeAddr + 4 expose the
// low and high halves respectively.
module corebus_clint
  import riscv_bus_pkg::*;
#(
  parameter logic [31:0] MtimeAddr = 32'h0200_bff8
) (
  input logic clk_i,
  input logic rst_ni,

  input  core_bus_req_t  req_i,
  output core_bus_resp_t resp_o
);

  logic [63:0] mtime_q;
  logic rsp_valid_q;
  logic [31:0] rsp_rdata_q;
  logic rsp_error_q;
  logic mtime_addr_hit;
  logic unused_write_payload;

  assign mtime_addr_hit = (req_i.addr == MtimeAddr) ||
      (req_i.addr == (MtimeAddr + 32'd4));
  assign unused_write_payload = ^{req_i.wdata, req_i.wstrb};

  assign resp_o.req_ready = !rsp_valid_q;
  assign resp_o.rdata = rsp_rdata_q;
  assign resp_o.error = rsp_error_q;
  assign resp_o.rsp_valid = rsp_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mtime_q <= 64'b0;
      rsp_valid_q <= 1'b0;
      rsp_rdata_q <= 32'b0;
      rsp_error_q <= 1'b0;
    end else begin
      mtime_q <= mtime_q + 64'd1;

      if (rsp_valid_q && req_i.rsp_ready) rsp_valid_q <= 1'b0;

      if (req_i.req_valid && resp_o.req_ready) begin
        rsp_valid_q <= 1'b1;
        rsp_error_q <= req_i.write || (req_i.size != CORE_BUS_SIZE_WORD) ||
            !mtime_addr_hit;
        if (!req_i.write && (req_i.size == CORE_BUS_SIZE_WORD) && mtime_addr_hit)
          rsp_rdata_q <= (req_i.addr == MtimeAddr) ? mtime_q[31:0] :
              mtime_q[63:32];
        else rsp_rdata_q <= 32'b0;
      end
    end
  end

endmodule
