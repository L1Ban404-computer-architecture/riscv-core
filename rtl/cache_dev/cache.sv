// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Shared cache development top.  This module connects the control, array, and
// AXI transport planes.  Its public CoreBus and AXI4 interfaces are
// intentionally stable.
`include "common/assertions.svh"

module cache
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
  import cache_pkg::*;
#(
  parameter bit ReadOnly = CacheDefaultReadOnly,
  parameter int unsigned BlockBytes = CacheDefaultBlockBytes,
  parameter int unsigned SetCount = CacheDefaultSetCount,
  parameter int unsigned WayCount = CacheDefaultWayCount,
  parameter int unsigned LookupLatency = CacheDefaultLookupLatency,
  parameter int unsigned MaxOutstanding = CacheDefaultMaxOutstanding,
  parameter axi4_id_t AxiId = DCACHE_AXI_ID,
  localparam int unsigned BlockOffsetW = $clog2(BlockBytes),
  localparam int unsigned BlockAddrW = XLen - BlockOffsetW,
  localparam int unsigned SetIndexBits = $clog2(SetCount),
  localparam int unsigned SetIndexW = (SetCount > 1) ? SetIndexBits : 1,
  localparam int unsigned TagW = BlockAddrW - SetIndexBits,
  localparam int unsigned WordCount = BlockBytes / StrbW,
  localparam int unsigned WordIndexBits = $clog2(WordCount),
  localparam int unsigned WordIndexW = (WordCount > 1) ? WordIndexBits : 1,
  localparam int unsigned WayIndexW = (WayCount > 1) ? $clog2   (WayCount) : 1,
  localparam int unsigned TxnIdW =
      (MaxOutstanding > 1) ? $clog2(MaxOutstanding) : 1,
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

  logic lookup_req_valid;
  logic lookup_req_ready;
  logic [TxnIdW-1:0] lookup_req_txn_id;
  logic lookup_req_epoch;
  logic [SetIndexW-1:0] lookup_req_set;
  logic [TagW-1:0] lookup_req_tag;
  logic [WordIndexW-1:0] lookup_req_word;

  logic lookup_rsp_valid;
  logic [TxnIdW-1:0] lookup_rsp_txn_id;
  logic lookup_rsp_epoch;
  logic lookup_rsp_hit;
  logic [WayIndexW-1:0] lookup_rsp_hit_way;
  word_t lookup_rsp_rdata;
  logic [WayIndexW-1:0] lookup_rsp_victim_way;
  logic [TagW-1:0] lookup_rsp_victim_tag;
  logic lookup_rsp_victim_valid;
  logic lookup_rsp_victim_dirty;

  logic victim_req_valid;
  logic victim_req_ready;
  logic [SetIndexW-1:0] victim_req_set;
  logic [WayIndexW-1:0] victim_req_way;

  logic victim_rsp_valid;
  logic victim_rsp_ready;
  logic [LineBits-1:0] victim_rsp_line;

  logic word_write_valid;
  logic word_write_ready;
  logic [SetIndexW-1:0] word_write_set;
  logic [WayIndexW-1:0] word_write_way;
  logic [WordIndexW-1:0] word_write_word;
  word_t word_write_data;

  logic line_install_valid;
  logic line_install_ready;
  logic [SetIndexW-1:0] line_install_set;
  logic [WayIndexW-1:0] line_install_way;
  logic [LineBits-1:0] line_install_data;
  logic [TagW-1:0] line_install_tag;
  logic line_install_dirty;

  logic replacement_update_valid;
  logic [SetIndexW-1:0] replacement_update_set;
  logic [WayIndexW-1:0] replacement_update_way;

  logic refill_req_valid;
  logic refill_req_ready;
  logic [BlockAddrW-1:0] refill_req_block_addr;
  logic refill_req_writeback_valid;
  logic [BlockAddrW-1:0] refill_req_writeback_block_addr;
  logic [LineBits-1:0] refill_req_writeback_data;

  logic refill_rsp_valid;
  logic refill_rsp_ready;
  logic [LineBits-1:0] refill_rsp_data;
  logic refill_rsp_error;

  cache_control #(
    .ReadOnly(ReadOnly),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .MaxOutstanding(MaxOutstanding)
  ) u_cache_control (
    .clk_i,
    .rst_ni,
    .core_req_i,
    .core_resp_o,
    .lookup_req_valid_o(lookup_req_valid),
    .lookup_req_ready_i(lookup_req_ready),
    .lookup_req_txn_id_o(lookup_req_txn_id),
    .lookup_req_epoch_o(lookup_req_epoch),
    .lookup_req_set_o(lookup_req_set),
    .lookup_req_tag_o(lookup_req_tag),
    .lookup_req_word_o(lookup_req_word),
    .lookup_rsp_valid_i(lookup_rsp_valid),
    .lookup_rsp_txn_id_i(lookup_rsp_txn_id),
    .lookup_rsp_epoch_i(lookup_rsp_epoch),
    .lookup_rsp_hit_i(lookup_rsp_hit),
    .lookup_rsp_hit_way_i(lookup_rsp_hit_way),
    .lookup_rsp_rdata_i(lookup_rsp_rdata),
    .lookup_rsp_victim_way_i(lookup_rsp_victim_way),
    .lookup_rsp_victim_tag_i(lookup_rsp_victim_tag),
    .lookup_rsp_victim_valid_i(lookup_rsp_victim_valid),
    .lookup_rsp_victim_dirty_i(lookup_rsp_victim_dirty),
    .victim_req_valid_o(victim_req_valid),
    .victim_req_ready_i(victim_req_ready),
    .victim_req_set_o(victim_req_set),
    .victim_req_way_o(victim_req_way),
    .victim_rsp_valid_i(victim_rsp_valid),
    .victim_rsp_ready_o(victim_rsp_ready),
    .victim_rsp_line_i(victim_rsp_line),
    .word_write_valid_o(word_write_valid),
    .word_write_ready_i(word_write_ready),
    .word_write_set_o(word_write_set),
    .word_write_way_o(word_write_way),
    .word_write_word_o(word_write_word),
    .word_write_data_o(word_write_data),
    .line_install_valid_o(line_install_valid),
    .line_install_ready_i(line_install_ready),
    .line_install_set_o(line_install_set),
    .line_install_way_o(line_install_way),
    .line_install_data_o(line_install_data),
    .line_install_tag_o(line_install_tag),
    .line_install_dirty_o(line_install_dirty),
    .replacement_update_valid_o(replacement_update_valid),
    .replacement_update_set_o(replacement_update_set),
    .replacement_update_way_o(replacement_update_way),
    .refill_req_valid_o(refill_req_valid),
    .refill_req_ready_i(refill_req_ready),
    .refill_req_block_addr_o(refill_req_block_addr),
    .refill_req_writeback_valid_o(refill_req_writeback_valid),
    .refill_req_writeback_block_addr_o(refill_req_writeback_block_addr),
    .refill_req_writeback_data_o(refill_req_writeback_data),
    .refill_rsp_valid_i(refill_rsp_valid),
    .refill_rsp_ready_o(refill_rsp_ready),
    .refill_rsp_data_i(refill_rsp_data),
    .refill_rsp_error_i(refill_rsp_error)
  );

  cache_array #(
    .ReadOnly(ReadOnly),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .LookupLatency(LookupLatency),
    .MaxOutstanding(MaxOutstanding)
  ) u_cache_array (
    .clk_i,
    .rst_ni,
    .lookup_req_valid_i(lookup_req_valid),
    .lookup_req_ready_o(lookup_req_ready),
    .lookup_req_txn_id_i(lookup_req_txn_id),
    .lookup_req_epoch_i(lookup_req_epoch),
    .lookup_req_set_i(lookup_req_set),
    .lookup_req_tag_i(lookup_req_tag),
    .lookup_req_word_i(lookup_req_word),
    .lookup_rsp_valid_o(lookup_rsp_valid),
    .lookup_rsp_txn_id_o(lookup_rsp_txn_id),
    .lookup_rsp_epoch_o(lookup_rsp_epoch),
    .lookup_rsp_hit_o(lookup_rsp_hit),
    .lookup_rsp_hit_way_o(lookup_rsp_hit_way),
    .lookup_rsp_rdata_o(lookup_rsp_rdata),
    .lookup_rsp_victim_way_o(lookup_rsp_victim_way),
    .lookup_rsp_victim_tag_o(lookup_rsp_victim_tag),
    .lookup_rsp_victim_valid_o(lookup_rsp_victim_valid),
    .lookup_rsp_victim_dirty_o(lookup_rsp_victim_dirty),
    .victim_req_valid_i(victim_req_valid),
    .victim_req_ready_o(victim_req_ready),
    .victim_req_set_i(victim_req_set),
    .victim_req_way_i(victim_req_way),
    .victim_rsp_valid_o(victim_rsp_valid),
    .victim_rsp_ready_i(victim_rsp_ready),
    .victim_rsp_line_o(victim_rsp_line),
    .word_write_valid_i(word_write_valid),
    .word_write_ready_o(word_write_ready),
    .word_write_set_i(word_write_set),
    .word_write_way_i(word_write_way),
    .word_write_word_i(word_write_word),
    .word_write_data_i(word_write_data),
    .line_install_valid_i(line_install_valid),
    .line_install_ready_o(line_install_ready),
    .line_install_set_i(line_install_set),
    .line_install_way_i(line_install_way),
    .line_install_data_i(line_install_data),
    .line_install_tag_i(line_install_tag),
    .line_install_dirty_i(line_install_dirty),
    .replacement_update_valid_i(replacement_update_valid),
    .replacement_update_set_i(replacement_update_set),
    .replacement_update_way_i(replacement_update_way)
  );

  cache_refill_engine #(
    .ReadOnly(ReadOnly),
    .BlockBytes(BlockBytes),
    .AxiId(AxiId)
  ) u_cache_refill_engine (
    .clk_i,
    .rst_ni,
    .refill_req_valid_i(refill_req_valid),
    .refill_req_ready_o(refill_req_ready),
    .refill_req_block_addr_i(refill_req_block_addr),
    .refill_req_writeback_valid_i(refill_req_writeback_valid),
    .refill_req_writeback_block_addr_i(refill_req_writeback_block_addr),
    .refill_req_writeback_data_i(refill_req_writeback_data),
    .refill_rsp_valid_o(refill_rsp_valid),
    .refill_rsp_ready_i(refill_rsp_ready),
    .refill_rsp_data_o(refill_rsp_data),
    .refill_rsp_error_o(refill_rsp_error),
    .axi_req_o,
    .axi_resp_i
  );

  `ASSERT_INIT(CacheBlockBytesValid,
               (BlockBytes >= StrbW) && cache_is_power_of_two(BlockBytes),
               "Cache line size must be a power of two and at least one AXI beat.")
  `ASSERT_INIT(CacheBlockBeatAligned, (BlockBytes % StrbW) == 0,
               "Cache line size must contain an integer number of AXI beats.")
  `ASSERT_INIT(CacheLineBeatCountValid, (LineBeats > 0) && (LineBeats <= 256),
               "An AXI4 burst may contain between one and 256 beats.")
  `ASSERT_INIT(CacheSetCountValid,
               cache_is_power_of_two(SetCount),
               "Cache set count must be a power of two.")
  `ASSERT_INIT(CacheWayCountValid,
               cache_is_power_of_two(WayCount),
               "Cache way count must be a power of two.")
  `ASSERT_INIT(CacheLookupLatencyValid, LookupLatency > 0,
               "Cache lookup latency must be greater than zero.")
  `ASSERT_INIT(CacheOutstandingDepthValid,
               (MaxOutstanding > 0) && (MaxOutstanding >= LookupLatency),
               "Outstanding capacity must cover the complete lookup pipeline.")
  `ASSERT_INIT(CacheBlockAddressWidthValid, BlockOffsetW < XLen,
               "Cache line size must be smaller than the CPU address space.")
  `ASSERT_INIT(CacheTagWidthValid, (SetIndexBits < BlockAddrW) && (TagW > 0),
               "Cache address decomposition must leave at least one tag bit.")
  `ASSERT_INIT(CacheWordIndexWidthValid, WordIndexBits <= BlockOffsetW,
               "The word index must fit inside the cache-line offset.")

  if (ReadOnly) begin : gen_read_only_assertions
    `ASSERT(CacheReadOnlyRequest,
            core_req_i.req_valid |-> !core_req_i.write,
            clk_i, !rst_ni, "A read-only cache must never receive a write request.")
  end

endmodule
