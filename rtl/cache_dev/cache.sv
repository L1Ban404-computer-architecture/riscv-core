// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Shared cache development top.  The same RTL is intended to become the
// instruction cache when ReadOnly is set and the data cache otherwise.
`include "common/assertions.svh"

import riscv_core_pkg::*;

module cache #(
  parameter bit ReadOnly = 1'b0,
  parameter int unsigned BlockBytes = 16,
  parameter int unsigned SetCount = 64,
  parameter int unsigned WayCount = 2,
  parameter int unsigned LookupLatency = 1,
  parameter int unsigned MaxOutstanding = 2,
  parameter axi4_id_t AxiId = DCACHE_AXI_ID,
  localparam int unsigned BlockOffsetW = $clog2(BlockBytes),
  localparam int unsigned BlockAddrW = XLen - BlockOffsetW,
  localparam int unsigned LineBits = BlockBytes * ByteW,
  localparam int unsigned LineBeats = BlockBytes / StrbW
) (
  input logic clk_i,
  input logic rst_ni,

  input  core_bus_req_t  core_req_i,
  output core_bus_resp_t core_resp_o,

  output axi4_req_t  axi_req_o,
  input  axi4_resp_t axi_resp_i
);

  logic line_req_valid;
  logic line_req_ready;
  logic [BlockAddrW-1:0] line_req_block_addr;
  logic line_req_write;
  logic [LineBits-1:0] line_req_wdata;
  logic [BlockBytes-1:0] line_req_wstrb;

  logic line_rsp_valid;
  logic line_rsp_ready;
  logic [LineBits-1:0] line_rsp_rdata;
  logic line_rsp_error;

  logic miss_req_valid;
  logic miss_req_ready;
  logic [BlockAddrW-1:0] miss_req_refill_block_addr;
  logic miss_req_writeback_valid;
  logic [BlockAddrW-1:0] miss_req_writeback_block_addr;
  logic [LineBits-1:0] miss_req_writeback_data;

  logic miss_rsp_valid;
  logic miss_rsp_ready;
  logic [LineBits-1:0] miss_rsp_refill_data;
  logic miss_rsp_error;

  cache_corebus_frontend #(
    .ReadOnly(ReadOnly),
    .BlockBytes(BlockBytes),
    .BlockAddrW(BlockAddrW),
    .LineBits(LineBits),
    .MaxOutstanding(MaxOutstanding)
  ) u_cache_corebus_frontend (
    .clk_i,
    .rst_ni,
    .core_req_i,
    .core_resp_o,
    .line_req_valid_o(line_req_valid),
    .line_req_ready_i(line_req_ready),
    .line_req_block_addr_o(line_req_block_addr),
    .line_req_write_o(line_req_write),
    .line_req_wdata_o(line_req_wdata),
    .line_req_wstrb_o(line_req_wstrb),
    .line_rsp_valid_i(line_rsp_valid),
    .line_rsp_ready_o(line_rsp_ready),
    .line_rsp_rdata_i(line_rsp_rdata),
    .line_rsp_error_i(line_rsp_error)
  );

  cache_array_system #(
    .ReadOnly(ReadOnly),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .LookupLatency(LookupLatency),
    .MaxOutstanding(MaxOutstanding),
    .BlockAddrW(BlockAddrW),
    .LineBits(LineBits)
  ) u_cache_array_system (
    .clk_i,
    .rst_ni,
    .line_req_valid_i(line_req_valid),
    .line_req_ready_o(line_req_ready),
    .line_req_block_addr_i(line_req_block_addr),
    .line_req_write_i(line_req_write),
    .line_req_wdata_i(line_req_wdata),
    .line_req_wstrb_i(line_req_wstrb),
    .line_rsp_valid_o(line_rsp_valid),
    .line_rsp_ready_i(line_rsp_ready),
    .line_rsp_rdata_o(line_rsp_rdata),
    .line_rsp_error_o(line_rsp_error),
    .miss_req_valid_o(miss_req_valid),
    .miss_req_ready_i(miss_req_ready),
    .miss_req_refill_block_addr_o(miss_req_refill_block_addr),
    .miss_req_writeback_valid_o(miss_req_writeback_valid),
    .miss_req_writeback_block_addr_o(miss_req_writeback_block_addr),
    .miss_req_writeback_data_o(miss_req_writeback_data),
    .miss_rsp_valid_i(miss_rsp_valid),
    .miss_rsp_ready_o(miss_rsp_ready),
    .miss_rsp_refill_data_i(miss_rsp_refill_data),
    .miss_rsp_error_i(miss_rsp_error)
  );

  cache_miss_handler #(
    .BlockBytes(BlockBytes),
    .BlockAddrW(BlockAddrW),
    .LineBits(LineBits),
    .LineBeats(LineBeats),
    .AxiId(AxiId)
  ) u_cache_miss_handler (
    .clk_i,
    .rst_ni,
    .miss_req_valid_i(miss_req_valid),
    .miss_req_ready_o(miss_req_ready),
    .miss_req_refill_block_addr_i(miss_req_refill_block_addr),
    .miss_req_writeback_valid_i(miss_req_writeback_valid),
    .miss_req_writeback_block_addr_i(miss_req_writeback_block_addr),
    .miss_req_writeback_data_i(miss_req_writeback_data),
    .miss_rsp_valid_o(miss_rsp_valid),
    .miss_rsp_ready_i(miss_rsp_ready),
    .miss_rsp_refill_data_o(miss_rsp_refill_data),
    .miss_rsp_error_o(miss_rsp_error),
    .axi_req_o,
    .axi_resp_i
  );

  `ASSERT_INIT(CacheBlockBytesValid,
               (BlockBytes >= StrbW) && ((BlockBytes & (BlockBytes - 1)) == 0),
               "Cache line size must be a power of two and at least one AXI beat.")
  `ASSERT_INIT(CacheBlockBeatAligned, (BlockBytes % StrbW) == 0,
               "Cache line size must contain an integer number of AXI beats.")
  `ASSERT_INIT(CacheLineBeatCountValid, (LineBeats > 0) && (LineBeats <= 256),
               "An AXI4 burst may contain between one and 256 beats.")
  `ASSERT_INIT(CacheSetCountValid,
               (SetCount > 0) && ((SetCount & (SetCount - 1)) == 0),
               "Cache set count must be a power of two.")
  `ASSERT_INIT(CacheWayCountValid,
               (WayCount > 0) && ((WayCount & (WayCount - 1)) == 0),
               "Cache way count must be a power of two.")
  `ASSERT_INIT(CacheLookupLatencyValid, LookupLatency > 0,
               "Cache lookup latency must be greater than zero.")
  `ASSERT_INIT(CacheOutstandingDepthValid, MaxOutstanding >= LookupLatency,
               "Outstanding capacity must cover the complete lookup pipeline.")
  `ASSERT_INIT(CacheBlockAddressWidthValid, BlockOffsetW < XLen,
               "Cache line size must be smaller than the CPU address space.")

  if (ReadOnly) begin : gen_read_only_assertions
    `ASSERT(CacheReadOnlyRequest,
            core_req_i.req_valid |-> !core_req_i.write,
            clk_i, !rst_ni, "A read-only cache must never receive a write request.")
  end

endmodule
