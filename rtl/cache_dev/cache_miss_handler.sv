// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Single-miss writeback/refill AXI4 engine skeleton.
import riscv_core_pkg::*;

module cache_miss_handler #(
  parameter int unsigned BlockBytes = 16,
  parameter int unsigned BlockAddrW = XLen - $clog2(BlockBytes),
  parameter int unsigned LineBits = BlockBytes * ByteW,
  parameter int unsigned LineBeats = BlockBytes / StrbW,
  parameter axi4_id_t AxiId = DCACHE_AXI_ID
) (
  input logic clk_i,
  input logic rst_ni,

  input logic miss_req_valid_i,
  output logic miss_req_ready_o,
  input logic [BlockAddrW-1:0] miss_req_refill_block_addr_i,
  input logic miss_req_writeback_valid_i,
  input logic [BlockAddrW-1:0] miss_req_writeback_block_addr_i,
  input logic [LineBits-1:0] miss_req_writeback_data_i,

  output logic miss_rsp_valid_o,
  input logic miss_rsp_ready_i,
  output logic [LineBits-1:0] miss_rsp_refill_data_o,
  output logic miss_rsp_error_o,

  output axi4_req_t axi_req_o,
  input axi4_resp_t axi_resp_i
);

  logic unused_inputs;

  always_comb begin
    miss_req_ready_o = 1'b0;
    miss_rsp_valid_o = 1'b0;
    miss_rsp_refill_data_o = '0;
    miss_rsp_error_o = 1'b0;
    axi_req_o = '0;
  end

  assign unused_inputs = ^{LineBeats, AxiId, miss_req_valid_i,
                           miss_req_refill_block_addr_i,
                           miss_req_writeback_valid_i,
                           miss_req_writeback_block_addr_i,
                           miss_req_writeback_data_i, miss_rsp_ready_i,
                           axi_resp_i, clk_i, rst_ni};

endmodule
