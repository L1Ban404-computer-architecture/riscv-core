// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// CoreBus-to-line adapter skeleton.  The implementation will atomically pair
// each accepted CoreBus request with its line request and metadata FIFO entry.
`include "common/assertions.svh"

import riscv_core_pkg::*;

module cache_corebus_frontend #(
  parameter bit ReadOnly = 1'b0,
  parameter int unsigned BlockBytes = 16,
  parameter int unsigned BlockAddrW = XLen - $clog2(BlockBytes),
  parameter int unsigned LineBits = BlockBytes * ByteW,
  parameter int unsigned MaxOutstanding = 2
) (
  input logic clk_i,
  input logic rst_ni,

  input  core_bus_req_t  core_req_i,
  output core_bus_resp_t core_resp_o,

  output logic line_req_valid_o,
  input logic line_req_ready_i,
  output logic [BlockAddrW-1:0] line_req_block_addr_o,
  output logic line_req_write_o,
  output logic [LineBits-1:0] line_req_wdata_o,
  output logic [BlockBytes-1:0] line_req_wstrb_o,

  input logic line_rsp_valid_i,
  output logic line_rsp_ready_o,
  input logic [LineBits-1:0] line_rsp_rdata_i,
  input logic line_rsp_error_i
);

  logic unused_inputs;

  // This development skeleton is deliberately inert.  Permanent request
  // backpressure makes accidental integration fail locally without emitting
  // an incomplete transaction toward the cache arrays or AXI.
  always_comb begin
    core_resp_o = '0;
    line_req_valid_o = 1'b0;
    line_req_block_addr_o = '0;
    line_req_write_o = 1'b0;
    line_req_wdata_o = '0;
    line_req_wstrb_o = '0;
    line_rsp_ready_o = 1'b0;
  end

  assign unused_inputs = ^{ReadOnly, MaxOutstanding, core_req_i,
                           line_req_ready_i, line_rsp_valid_i,
                           line_rsp_rdata_i, line_rsp_error_i};

  `ASSERT(CacheFrontendSkeletonUnused,
          !core_req_i.req_valid,
          clk_i, !rst_ni,
          "cache_dev is an interface skeleton and must not receive CoreBus requests.")

endmodule
