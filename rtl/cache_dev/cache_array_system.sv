// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Set-associative cache array and ordered lookup-control skeleton.
import riscv_core_pkg::*;

module cache_array_system #(
  parameter bit ReadOnly = 1'b0,
  parameter int unsigned BlockBytes = 16,
  parameter int unsigned SetCount = 64,
  parameter int unsigned WayCount = 2,
  parameter int unsigned LookupLatency = 1,
  parameter int unsigned MaxOutstanding = 2,
  parameter int unsigned BlockAddrW = XLen - $clog2(BlockBytes),
  parameter int unsigned LineBits = BlockBytes * ByteW
) (
  input logic clk_i,
  input logic rst_ni,

  input logic line_req_valid_i,
  output logic line_req_ready_o,
  input logic [BlockAddrW-1:0] line_req_block_addr_i,
  input logic line_req_write_i,
  input logic [LineBits-1:0] line_req_wdata_i,
  input logic [BlockBytes-1:0] line_req_wstrb_i,

  output logic line_rsp_valid_o,
  input logic line_rsp_ready_i,
  output logic [LineBits-1:0] line_rsp_rdata_o,
  output logic line_rsp_error_o,

  output logic miss_req_valid_o,
  input logic miss_req_ready_i,
  output logic [BlockAddrW-1:0] miss_req_refill_block_addr_o,
  output logic miss_req_writeback_valid_o,
  output logic [BlockAddrW-1:0] miss_req_writeback_block_addr_o,
  output logic [LineBits-1:0] miss_req_writeback_data_o,

  input logic miss_rsp_valid_i,
  output logic miss_rsp_ready_o,
  input logic [LineBits-1:0] miss_rsp_refill_data_i,
  input logic miss_rsp_error_i
);

  logic unused_inputs;

  always_comb begin
    line_req_ready_o = 1'b0;
    line_rsp_valid_o = 1'b0;
    line_rsp_rdata_o = '0;
    line_rsp_error_o = 1'b0;

    miss_req_valid_o = 1'b0;
    miss_req_refill_block_addr_o = '0;
    miss_req_writeback_valid_o = 1'b0;
    miss_req_writeback_block_addr_o = '0;
    miss_req_writeback_data_o = '0;
    miss_rsp_ready_o = 1'b0;
  end

  assign unused_inputs = ^{ReadOnly, SetCount, WayCount, LookupLatency,
                           MaxOutstanding, line_req_valid_i,
                           line_req_block_addr_i, line_req_write_i,
                           line_req_wdata_i, line_req_wstrb_i,
                           line_rsp_ready_i, miss_req_ready_i,
                           miss_rsp_valid_i, miss_rsp_refill_data_i,
                           miss_rsp_error_i, clk_i, rst_ni};

endmodule
