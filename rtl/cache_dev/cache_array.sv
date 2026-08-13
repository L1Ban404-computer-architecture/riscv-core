// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Cache data plane.  Raw per-way metadata never crosses this boundary: tag
// comparison, hit data selection, victim selection, and Tree-PLRU live next to
// the physical arrays.  Lookup responses are fixed-latency completion events.
`include "common/assertions.svh"

module cache_array
  import riscv_common_pkg::*;
  import cache_pkg::*;
#(
  parameter bit ReadOnly = CacheDefaultReadOnly,
  parameter int unsigned BlockBytes = CacheDefaultBlockBytes,
  parameter int unsigned SetCount = CacheDefaultSetCount,
  parameter int unsigned WayCount = CacheDefaultWayCount,
  parameter int unsigned LookupLatency = CacheDefaultLookupLatency,
  parameter int unsigned MaxOutstanding = CacheDefaultMaxOutstanding,
  localparam int unsigned BlockOffsetW = $clog2(BlockBytes),
  localparam int unsigned BlockAddrW = XLen - BlockOffsetW,
  localparam int unsigned SetIndexBits = $clog2(SetCount),
  localparam int unsigned SetIndexW = (SetCount > 1) ? SetIndexBits : 1,
  localparam int unsigned TagW = BlockAddrW - SetIndexBits,
  localparam int unsigned WordCount = BlockBytes / StrbW,
  localparam int unsigned WordIndexW =
      (WordCount > 1) ? $clog2(WordCount) : 1,
  localparam int unsigned WayIndexW =
      (WayCount > 1) ? $clog2(WayCount) : 1,
  localparam int unsigned TxnIdW =
      (MaxOutstanding > 1) ? $clog2(MaxOutstanding) : 1,
  localparam int unsigned LineBits = BlockBytes * ByteW
) (
  input logic clk_i,
  input logic rst_ni,

  input logic lookup_req_valid_i,
  output logic lookup_req_ready_o,
  input logic [TxnIdW-1:0] lookup_req_txn_id_i,
  input logic lookup_req_epoch_i,
  input logic [SetIndexW-1:0] lookup_req_set_i,
  input logic [TagW-1:0] lookup_req_tag_i,
  input logic [WordIndexW-1:0] lookup_req_word_i,

  output logic lookup_rsp_valid_o,
  output logic [TxnIdW-1:0] lookup_rsp_txn_id_o,
  output logic lookup_rsp_epoch_o,
  output logic lookup_rsp_hit_o,
  output logic [WayIndexW-1:0] lookup_rsp_hit_way_o,
  output word_t lookup_rsp_rdata_o,
  output logic [WayIndexW-1:0] lookup_rsp_victim_way_o,
  output logic [TagW-1:0] lookup_rsp_victim_tag_o,
  output logic lookup_rsp_victim_valid_o,
  output logic lookup_rsp_victim_dirty_o,

  input logic victim_req_valid_i,
  output logic victim_req_ready_o,
  input logic [SetIndexW-1:0] victim_req_set_i,
  input logic [WayIndexW-1:0] victim_req_way_i,

  output logic victim_rsp_valid_o,
  input logic victim_rsp_ready_i,
  output logic [LineBits-1:0] victim_rsp_line_o,

  input logic write_valid_i,
  output logic write_ready_o,
  input cache_array_write_kind_e write_kind_i,
  input logic [SetIndexW-1:0] write_set_i,
  input logic [WayIndexW-1:0] write_way_i,
  input logic [WordIndexW-1:0] write_word_i,
  input word_t write_word_data_i,
  input logic [LineBits-1:0] write_line_data_i,
  input logic [TagW-1:0] write_tag_i,
  input logic write_dirty_i,

  input logic replacement_update_valid_i,
  input logic [SetIndexW-1:0] replacement_update_set_i,
  input logic [WayIndexW-1:0] replacement_update_way_i
);

  typedef logic [TxnIdW-1:0] txn_id_t;
  typedef logic [WayIndexW-1:0] way_index_t;
  typedef logic [TagW-1:0] tag_t;

  typedef struct packed {
    txn_id_t txn_id;
    logic epoch;
    logic [SetIndexW-1:0] set;
    tag_t tag;
    logic [WordIndexW-1:0] word;
  } lookup_req_t;

  typedef struct packed {
    txn_id_t txn_id;
    logic epoch;
    logic hit;
    way_index_t hit_way;
    word_t rdata;
    way_index_t victim_way;
    tag_t victim_tag;
    logic victim_valid;
    logic victim_dirty;
  } lookup_rsp_t;

  logic [TagW-1:0] tag_mem[WayCount][SetCount];
  logic valid_mem[WayCount][SetCount];
  logic [WayCount-1:0] dirty_read;

  word_t bank_read_data[WayCount][WordCount];
  logic bank_read_valid[WayCount][WordCount];
  logic [SetIndexW-1:0] bank_read_set;
  logic bank_write_valid[WayCount][WordCount];
  word_t bank_write_data[WayCount][WordCount];

  logic lookup_fire;
  logic victim_fire;
  logic write_fire;

  logic lookup_base_valid_q;
  lookup_req_t lookup_req_q;
  logic [WayCount-1:0][TagW-1:0] lookup_tags_q;
  logic [WayCount-1:0] lookup_valids_q;
  logic [WayCount-1:0] lookup_dirty_q;
  logic [WayCount-1:0] lookup_hit_vector;
  logic lookup_hit;
  logic [WayIndexW-1:0] lookup_hit_way;
  logic [WayIndexW-1:0] lookup_victim_way;
  lookup_rsp_t lookup_base_rsp;
  lookup_rsp_t lookup_rsp;

  logic victim_rsp_valid_q;
  logic [WayIndexW-1:0] victim_way_q;

  // A pending victim response reserves the data banks until it is consumed.
  // Among new operations, writes have priority over victim reads and lookups.
  assign write_ready_o = !victim_rsp_valid_q || victim_rsp_ready_i;
  assign victim_req_ready_o = write_ready_o && !write_valid_i;
  assign lookup_req_ready_o =
      victim_req_ready_o && !victim_req_valid_i;

  assign lookup_fire = lookup_req_valid_i && lookup_req_ready_o;
  assign victim_fire = victim_req_valid_i && victim_req_ready_o;
  assign write_fire = write_valid_i && write_ready_o;
  assign bank_read_set = victim_fire ? victim_req_set_i : lookup_req_set_i;

  for (genvar way = 0; way < WayCount; way++) begin : gen_way
    for (genvar bank = 0; bank < WordCount; bank++) begin : gen_word_bank
      assign bank_read_valid[way][bank] =
          (lookup_fire &&
           (lookup_req_word_i == WordIndexW'(bank))) ||
          (victim_fire &&
           (victim_req_way_i == WayIndexW'(way)));
      assign bank_write_valid[way][bank] = write_fire &&
          (write_way_i == WayIndexW'(way)) &&
          ((write_kind_i == CacheWriteLine) ||
           (write_word_i == WordIndexW'(bank)));
      assign bank_write_data[way][bank] =
          (write_kind_i == CacheWriteLine) ?
          write_line_data_i[bank * XLen +: XLen] : write_word_data_i;

      cache_data_bank #(
        .SetCount(SetCount)
      ) u_data_bank (
        .clk_i,
        .rst_ni,
        .read_valid_i(bank_read_valid[way][bank]),
        .read_set_i(bank_read_set),
        .read_data_o(bank_read_data[way][bank]),
        .write_valid_i(bank_write_valid[way][bank]),
        .write_set_i(write_set_i),
        .write_data_i(bank_write_data[way][bank])
      );
    end
  end

  if (ReadOnly) begin : gen_no_dirty_array
    assign dirty_read = '0;
  end else begin : gen_dirty_array
    logic dirty_mem[WayCount][SetCount];

    for (genvar way = 0; way < WayCount; way++) begin : gen_dirty_read
      assign dirty_read[way] = dirty_mem[way][lookup_req_set_i];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned way = 0; way < WayCount; way++) begin
          for (int unsigned set = 0; set < SetCount; set++) begin
            dirty_mem[way][set] <= 1'b0;
          end
        end
      end else if (write_fire) begin
        if (write_kind_i == CacheWriteLine)
          dirty_mem[write_way_i][write_set_i] <= write_dirty_i;
        else
          dirty_mem[write_way_i][write_set_i] <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned way = 0; way < WayCount; way++) begin
        for (int unsigned set = 0; set < SetCount; set++) begin
          valid_mem[way][set] <= 1'b0;
        end
      end
    end else if (write_fire && (write_kind_i == CacheWriteLine)) begin
      valid_mem[write_way_i][write_set_i] <= 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (write_fire && (write_kind_i == CacheWriteLine))
      tag_mem[write_way_i][write_set_i] <= write_tag_i;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) lookup_base_valid_q <= 1'b0;
    else lookup_base_valid_q <= lookup_fire;
  end

  // Tag and metadata reads use the same request edge as the selected word-bank
  // reads.  Only valid state is reset; tag and data payloads remain unreset.
  always_ff @(posedge clk_i) begin
    if (lookup_fire) begin
      lookup_req_q.txn_id <= lookup_req_txn_id_i;
      lookup_req_q.epoch <= lookup_req_epoch_i;
      lookup_req_q.set <= lookup_req_set_i;
      lookup_req_q.tag <= lookup_req_tag_i;
      lookup_req_q.word <= lookup_req_word_i;
      for (int unsigned way = 0; way < WayCount; way++) begin
        lookup_tags_q[way] <= tag_mem[way][lookup_req_set_i];
        lookup_valids_q[way] <= valid_mem[way][lookup_req_set_i];
        lookup_dirty_q[way] <= dirty_read[way];
      end
    end
  end

  always_comb begin
    lookup_hit_vector = '0;
    for (int unsigned way = 0; way < WayCount; way++) begin
      lookup_hit_vector[way] = lookup_valids_q[way] &&
          (lookup_tags_q[way] == lookup_req_q.tag);
    end
  end

  assign lookup_hit = |lookup_hit_vector;
  always_comb begin
    logic hit_found;

    lookup_hit_way = '0;
    hit_found = 1'b0;
    for (int unsigned way = 0; way < WayCount; way++) begin
      if (!hit_found && lookup_hit_vector[way]) begin
        lookup_hit_way = WayIndexW'(way);
        hit_found = 1'b1;
      end
    end
  end

  always_comb begin
    lookup_base_rsp = '0;
    lookup_base_rsp.txn_id = lookup_req_q.txn_id;
    lookup_base_rsp.epoch = lookup_req_q.epoch;
    lookup_base_rsp.hit = lookup_hit;
    lookup_base_rsp.hit_way = lookup_hit_way;
    lookup_base_rsp.rdata =
        bank_read_data[lookup_hit_way][lookup_req_q.word];
    lookup_base_rsp.victim_way = lookup_victim_way;
    lookup_base_rsp.victim_tag = lookup_tags_q[lookup_victim_way];
    lookup_base_rsp.victim_valid = lookup_valids_q[lookup_victim_way];
    lookup_base_rsp.victim_dirty = lookup_dirty_q[lookup_victim_way];
  end

  if (LookupLatency == 1) begin : gen_one_cycle_lookup
    assign lookup_rsp_valid_o = lookup_base_valid_q;
    assign lookup_rsp = lookup_base_rsp;
  end else begin : gen_pipelined_lookup
    lookup_rsp_t payload_q[LookupLatency-1];
    logic [LookupLatency-2:0] valid_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        valid_q <= '0;
      end else begin
        valid_q[0] <= lookup_base_valid_q;
        for (int unsigned stage = 1; stage < LookupLatency - 1; stage++) begin
          valid_q[stage] <= valid_q[stage-1];
        end
      end
    end

    always_ff @(posedge clk_i) begin
      if (lookup_base_valid_q) payload_q[0] <= lookup_base_rsp;
      for (int unsigned stage = 1; stage < LookupLatency - 1; stage++) begin
        if (valid_q[stage-1]) payload_q[stage] <= payload_q[stage-1];
      end
    end

    assign lookup_rsp_valid_o = valid_q[LookupLatency-2];
    assign lookup_rsp = payload_q[LookupLatency-2];
  end

  assign lookup_rsp_txn_id_o = lookup_rsp.txn_id;
  assign lookup_rsp_epoch_o = lookup_rsp.epoch;
  assign lookup_rsp_hit_o = lookup_rsp.hit;
  assign lookup_rsp_hit_way_o = lookup_rsp.hit_way;
  assign lookup_rsp_rdata_o = lookup_rsp.rdata;
  assign lookup_rsp_victim_way_o = lookup_rsp.victim_way;
  assign lookup_rsp_victim_tag_o = lookup_rsp.victim_tag;
  assign lookup_rsp_victim_valid_o = lookup_rsp.victim_valid;
  assign lookup_rsp_victim_dirty_o = lookup_rsp.victim_dirty;

  assign victim_rsp_valid_o = victim_rsp_valid_q;
  always_comb begin
    victim_rsp_line_o = '0;
    for (int unsigned bank = 0; bank < WordCount; bank++) begin
      victim_rsp_line_o[bank * XLen +: XLen] =
          bank_read_data[victim_way_q][bank];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      victim_rsp_valid_q <= 1'b0;
      victim_way_q <= '0;
    end else begin
      if (victim_rsp_valid_q && victim_rsp_ready_i)
        victim_rsp_valid_q <= 1'b0;
      if (victim_fire) begin
        victim_rsp_valid_q <= 1'b1;
        victim_way_q <= victim_req_way_i;
      end
    end
  end

  cache_replacement_policy #(
    .SetCount(SetCount),
    .WayCount(WayCount)
  ) u_replacement_policy (
    .clk_i,
    .rst_ni,
    .select_set_i(lookup_req_q.set),
    .select_valid_i(lookup_valids_q),
    .victim_way_o(lookup_victim_way),
    .access_valid_i(replacement_update_valid_i),
    .access_set_i(replacement_update_set_i),
    .access_way_i(replacement_update_way_i)
  );

  // verilog_format: off
  `ASSERT_INIT(CacheArrayLookupLatencyValid, LookupLatency > 0,
               "Cache lookup latency must be positive.")
  `ASSERT(CacheArrayLookupResponseFixedLatency,
          lookup_rsp_valid_o == $past(lookup_fire, LookupLatency),
          clk_i, !rst_ni,
          "Every accepted lookup must return after exactly LookupLatency cycles.")
  `ASSERT(CacheArrayOperationsExclusive,
          $onehot0({lookup_fire, victim_fire, write_fire}),
          clk_i, !rst_ni,
          "Lookup, victim read, and cache write operations must be exclusive.")
  `ASSERT(CacheArrayLookupRequestStable,
          lookup_req_valid_i && !lookup_req_ready_o |=>
              $stable({lookup_req_valid_i, lookup_req_txn_id_i,
                       lookup_req_epoch_i, lookup_req_set_i, lookup_req_tag_i,
                       lookup_req_word_i}),
          clk_i, !rst_ni,
          "Lookup request payload must remain stable while backpressured.")
  `ASSERT(CacheArrayVictimRequestStable,
          victim_req_valid_i && !victim_req_ready_o |=>
              $stable({victim_req_valid_i, victim_req_set_i,
                       victim_req_way_i}),
          clk_i, !rst_ni,
          "Victim request payload must remain stable while backpressured.")
  `ASSERT(CacheArrayWriteStable,
          write_valid_i && !write_ready_o |=>
              $stable({write_valid_i, write_kind_i, write_set_i, write_way_i,
                       write_word_i, write_word_data_i, write_line_data_i,
                       write_tag_i, write_dirty_i}),
          clk_i, !rst_ni,
          "Array write payload must remain stable while backpressured.")
  `ASSERT(CacheArrayVictimResponseStable,
          victim_rsp_valid_o && !victim_rsp_ready_i |=>
              $stable({victim_rsp_valid_o, victim_rsp_line_o}),
          clk_i, !rst_ni,
          "Victim line must remain stable while its response is backpressured.")
  `ASSERT(CacheArrayLookupHitUnique,
          lookup_base_valid_q |-> $onehot0(lookup_hit_vector),
          clk_i, !rst_ni,
          "At most one way may match a lookup tag.")
  `ASSERT(CacheArrayVictimWayValid,
          lookup_base_valid_q |->
              (int'(lookup_base_rsp.victim_way) < WayCount),
          clk_i, !rst_ni,
          "A lookup must resolve to an implemented victim way.")
  // verilog_format: on

  if (ReadOnly) begin : gen_read_only_assertions
    `ASSERT(CacheArrayReadOnlyWordWrite,
            write_valid_i |-> (write_kind_i == CacheWriteLine),
            clk_i, !rst_ni,
            "A read-only cache may install refill lines but cannot commit stores.")
    `ASSERT(CacheArrayReadOnlyDirtyInstall,
            write_valid_i |-> !write_dirty_i,
            clk_i, !rst_ni,
            "A read-only cache must install clean lines.")
  end

endmodule
