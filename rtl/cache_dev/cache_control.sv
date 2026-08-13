// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Ordered cache control plane.  This module owns CoreBus admission and
// response ordering, the transaction table, the single store context, miss
// drain/replay, and scheduling of the semantic array/refill protocols.
`include "common/assertions.svh"

module cache_control
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
  import cache_pkg::*;
#(
  parameter bit ReadOnly = CacheDefaultReadOnly,
  parameter int unsigned BlockBytes = CacheDefaultBlockBytes,
  parameter int unsigned SetCount = CacheDefaultSetCount,
  parameter int unsigned WayCount = CacheDefaultWayCount,
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

  input  core_bus_req_t  core_req_i,
  output core_bus_resp_t core_resp_o,

  output logic lookup_req_valid_o,
  input logic lookup_req_ready_i,
  output logic [TxnIdW-1:0] lookup_req_txn_id_o,
  output logic lookup_req_epoch_o,
  output logic [SetIndexW-1:0] lookup_req_set_o,
  output logic [TagW-1:0] lookup_req_tag_o,
  output logic [WordIndexW-1:0] lookup_req_word_o,

  input logic lookup_rsp_valid_i,
  input logic [TxnIdW-1:0] lookup_rsp_txn_id_i,
  input logic lookup_rsp_epoch_i,
  input logic lookup_rsp_hit_i,
  input logic [WayIndexW-1:0] lookup_rsp_hit_way_i,
  input word_t lookup_rsp_rdata_i,
  input logic [WayIndexW-1:0] lookup_rsp_victim_way_i,
  input logic [TagW-1:0] lookup_rsp_victim_tag_i,
  input logic lookup_rsp_victim_valid_i,
  input logic lookup_rsp_victim_dirty_i,

  output logic victim_req_valid_o,
  input logic victim_req_ready_i,
  output logic [SetIndexW-1:0] victim_req_set_o,
  output logic [WayIndexW-1:0] victim_req_way_o,

  input logic victim_rsp_valid_i,
  output logic victim_rsp_ready_o,
  input logic [LineBits-1:0] victim_rsp_line_i,

  output logic word_write_valid_o,
  input logic word_write_ready_i,
  output logic [SetIndexW-1:0] word_write_set_o,
  output logic [WayIndexW-1:0] word_write_way_o,
  output logic [WordIndexW-1:0] word_write_word_o,
  output word_t word_write_data_o,

  output logic line_install_valid_o,
  input logic line_install_ready_i,
  output logic [SetIndexW-1:0] line_install_set_o,
  output logic [WayIndexW-1:0] line_install_way_o,
  output logic [LineBits-1:0] line_install_data_o,
  output logic [TagW-1:0] line_install_tag_o,
  output logic line_install_dirty_o,

  output logic replacement_update_valid_o,
  output logic [SetIndexW-1:0] replacement_update_set_o,
  output logic [WayIndexW-1:0] replacement_update_way_o,

  output logic refill_req_valid_o,
  input logic refill_req_ready_i,
  output logic [BlockAddrW-1:0] refill_req_block_addr_o,
  output logic refill_req_writeback_valid_o,
  output logic [BlockAddrW-1:0] refill_req_writeback_block_addr_o,
  output logic [LineBits-1:0] refill_req_writeback_data_o,

  input logic refill_rsp_valid_i,
  output logic refill_rsp_ready_o,
  input logic [LineBits-1:0] refill_rsp_data_i,
  input logic refill_rsp_error_i
);

  localparam int unsigned TxnCountW =
      (MaxOutstanding > 1) ? $clog2(MaxOutstanding + 1) : 1;

  typedef logic [TxnIdW-1:0] txn_id_t;
  typedef logic [TxnCountW-1:0] txn_count_t;
  typedef logic [BlockAddrW-1:0] block_addr_t;
  typedef logic [SetIndexW-1:0] set_index_t;
  typedef logic [WordIndexW-1:0] word_index_t;
  typedef logic [WayIndexW-1:0] way_index_t;
  typedef logic [TagW-1:0] tag_t;

  typedef enum logic [2:0] {
    TxnFree,
    TxnInflight,
    TxnReplay,
    TxnStoreCommit,
    TxnMiss,
    TxnDone
  } txn_state_e;

  typedef enum logic [2:0] {
    StateRun,
    StateStoreCommit,
    StateMissDrain,
    StateVictimRead,
    StateRefillRequest,
    StateRefillWait,
    StateReplay
  } state_e;

  typedef struct packed {
    block_addr_t block_addr;
    word_index_t word;
    txn_state_e state;
    word_t rdata;
    logic error;
  } txn_entry_t;

  typedef struct packed {
    set_index_t set;
    word_index_t word;
    way_index_t way;
    word_t data;
  } store_hit_t;

  typedef struct packed {
    logic active;
    txn_id_t txn_id;
    word_t wdata;
    byte_en_t wstrb;
    set_index_t commit_set;
    word_index_t commit_word;
    way_index_t commit_way;
    word_t commit_data;
  } store_context_t;

  typedef struct packed {
    txn_id_t owner;
    block_addr_t block_addr;
    set_index_t set;
    word_index_t word;
    tag_t tag;
    way_index_t victim_way;
    tag_t victim_tag;
    logic victim_dirty;
    logic is_store;
    logic victim_req_sent;
  } miss_context_t;

  txn_entry_t txn_q[MaxOutstanding];
  txn_entry_t txn_d[MaxOutstanding];
  store_context_t store_context;
  miss_context_t miss_context_q;

  txn_id_t head_q;
  txn_id_t tail_q;
  txn_count_t usage_q;
  txn_count_t lookup_inflight_q;
  logic epoch_q;
  state_e state_q;
  state_e state_d;

  txn_id_t replay_ptr_q;
  txn_count_t replay_remaining_q;

  logic core_request_fire;
  logic core_response_fire;
  logic queue_credit;
  logic direct_lookup_allowed;
  logic direct_lookup_valid;
  logic replay_lookup_valid;
  logic lookup_req_fire;
  logic lookup_response_current;
  logic lookup_response_store;
  logic lookup_response_miss;

  logic victim_req_fire;
  logic refill_req_fire;
  logic refill_rsp_fire;
  logic word_write_fire;
  logic line_install_fire;
  logic store_commit_fire;

  logic store_capture;
  logic store_release;
  logic store_hit_capture;
  store_hit_t store_hit;

  txn_count_t existing_younger_count;
  txn_count_t miss_younger_count;
  txn_id_t next_miss_owner;

  logic replacement_load_hit;
  logic replacement_store_commit;
  logic replacement_refill_install;

  function automatic txn_id_t next_txn_id(input txn_id_t id);
    if (id == txn_id_t'(MaxOutstanding - 1)) return '0;
    return id + txn_id_t'(1);
  endfunction

  function automatic txn_count_t queue_distance(
    input txn_id_t from,
    input txn_id_t to
  );
    if (to >= from) return txn_count_t'(to - from);
    return txn_count_t'(MaxOutstanding - int'(from) + int'(to));
  endfunction

  function automatic set_index_t block_set(input block_addr_t block_addr);
    if (SetCount == 1) return '0;
    return set_index_t'(block_addr % BlockAddrW'(SetCount));
  endfunction

  function automatic tag_t block_tag(input block_addr_t block_addr);
    return tag_t'(block_addr >> SetIndexBits);
  endfunction

  function automatic word_index_t address_word(input word_t address);
    if (WordCount == 1) return '0;
    return word_index_t'(address >> 2);
  endfunction

  function automatic block_addr_t victim_block_addr(
    input tag_t tag,
    input set_index_t set
  );
    block_addr_t result;

    result = BlockAddrW'(tag);
    result = result << SetIndexBits;
    if (SetCount > 1) result |= BlockAddrW'(set);
    return result;
  endfunction

  function automatic logic [LineBits-1:0] merge_store_line(
    input logic [LineBits-1:0] old_line,
    input word_index_t word_index,
    input word_t new_word,
    input byte_en_t strobe
  );
    logic [LineBits-1:0] updated_line;
    word_t old_word;

    updated_line = old_line;
    old_word = old_line[int'(word_index) * XLen +: XLen];
    updated_line[int'(word_index) * XLen +: XLen] =
        cache_merge_store_word(old_word, new_word, strobe);
    return updated_line;
  endfunction

  // 根据 CoreBus 地址和传输宽度生成写请求应携带的 byte strobe。该函数只服务于
  // 本模块的协议 assertion，因此与 CoreBus 类型一起保留在总线边界内部。
  function automatic byte_en_t expected_store_strobe(
    input word_t address,
    input core_bus_size_e size
  );
    byte_en_t base_strobe;

    unique case (size)
      CORE_BUS_SIZE_BYTE: base_strobe = byte_en_t'(1);
      CORE_BUS_SIZE_HALF: base_strobe = byte_en_t'(3);
      CORE_BUS_SIZE_WORD: base_strobe = '1;
      default: base_strobe = '0;
    endcase
    return byte_en_t'(base_strobe << int'(address % StrbW));
  endfunction

  // CoreBus completion is sourced exclusively from the ordered table head.
  assign core_resp_o.rsp_valid =
      (usage_q != '0) && (txn_q[head_q].state == TxnDone);
  assign core_resp_o.rdata = txn_q[head_q].rdata;
  assign core_resp_o.error = txn_q[head_q].error;
  assign core_response_fire = core_resp_o.rsp_valid && core_req_i.rsp_ready;

  assign queue_credit =
      (usage_q < txn_count_t'(MaxOutstanding)) || core_response_fire;
  assign direct_lookup_allowed = (state_q == StateRun) &&
      !store_context.active && queue_credit &&
      (!ReadOnly || !core_req_i.write) &&
      (!core_req_i.write || (lookup_inflight_q == '0));
  assign direct_lookup_valid = direct_lookup_allowed && core_req_i.req_valid;
  assign replay_lookup_valid =
      (state_q == StateReplay) && (replay_remaining_q != '0);

  always_comb begin
    lookup_req_valid_o = 1'b0;
    lookup_req_txn_id_o = '0;
    lookup_req_epoch_o = epoch_q;
    lookup_req_set_o = '0;
    lookup_req_tag_o = '0;
    lookup_req_word_o = '0;

    if (replay_lookup_valid) begin
      lookup_req_valid_o = 1'b1;
      lookup_req_txn_id_o = replay_ptr_q;
      lookup_req_set_o = block_set(txn_q[replay_ptr_q].block_addr);
      lookup_req_tag_o = block_tag(txn_q[replay_ptr_q].block_addr);
      lookup_req_word_o = txn_q[replay_ptr_q].word;
    end else if (direct_lookup_valid) begin
      lookup_req_valid_o = 1'b1;
      lookup_req_txn_id_o = tail_q;
      lookup_req_set_o =
          block_set(core_req_i.addr[XLen-1:BlockOffsetW]);
      lookup_req_tag_o =
          block_tag(core_req_i.addr[XLen-1:BlockOffsetW]);
      lookup_req_word_o = address_word(core_req_i.addr);
    end
  end

  assign core_resp_o.req_ready =
      direct_lookup_allowed && lookup_req_ready_i;
  assign core_request_fire = core_req_i.req_valid && core_resp_o.req_ready;
  assign lookup_req_fire = lookup_req_valid_o && lookup_req_ready_i;

  assign lookup_response_current =
      lookup_rsp_valid_i && (lookup_rsp_epoch_i == epoch_q);
  assign lookup_response_store = store_context.active &&
      (store_context.txn_id == lookup_rsp_txn_id_i);
  assign lookup_response_miss =
      lookup_response_current && !lookup_rsp_hit_i;

  assign next_miss_owner = lookup_rsp_txn_id_i;
  assign existing_younger_count =
      queue_distance(next_txn_id(next_miss_owner), tail_q);
  assign miss_younger_count = existing_younger_count +
      txn_count_t'(core_request_fire);

  always_comb begin
    state_d = state_q;

    unique case (state_q)
      StateRun: ;

      StateStoreCommit: begin
        if (store_commit_fire) state_d = StateRun;
      end

      StateMissDrain: begin
        if (lookup_inflight_q == '0) begin
          if (miss_context_q.victim_dirty) state_d = StateVictimRead;
          else state_d = StateRefillRequest;
        end
      end

      StateVictimRead: begin
        if (refill_req_fire) state_d = StateRefillWait;
      end

      StateRefillRequest: begin
        if (refill_req_fire) state_d = StateRefillWait;
      end

      StateRefillWait: begin
        if (refill_rsp_fire) begin
          if (replay_remaining_q != '0) state_d = StateReplay;
          else state_d = StateRun;
        end
      end

      StateReplay: begin
        if (lookup_req_fire &&
            (replay_remaining_q == txn_count_t'(1)))
          state_d = StateRun;
      end

      default: state_d = StateRun;
    endcase

    if (lookup_response_current) begin
      if (lookup_response_miss) state_d = StateMissDrain;
      else if (lookup_response_store) state_d = StateStoreCommit;
    end
  end

  // Dirty victims flow directly from the array response into the refill
  // request.  The control plane deliberately contains no second line buffer.
  always_comb begin
    victim_req_valid_o = 1'b0;
    victim_req_set_o = miss_context_q.set;
    victim_req_way_o = miss_context_q.victim_way;
    victim_rsp_ready_o = 1'b0;

    refill_req_valid_o = 1'b0;
    refill_req_block_addr_o = miss_context_q.block_addr;
    refill_req_writeback_valid_o = 1'b0;
    refill_req_writeback_block_addr_o =
        victim_block_addr(miss_context_q.victim_tag, miss_context_q.set);
    refill_req_writeback_data_o = victim_rsp_line_i;

    if (state_q == StateVictimRead) begin
      victim_req_valid_o = !miss_context_q.victim_req_sent;
      refill_req_valid_o = victim_rsp_valid_i;
      refill_req_writeback_valid_o = 1'b1;
      victim_rsp_ready_o = refill_req_ready_i;
    end else if (state_q == StateRefillRequest) begin
      refill_req_valid_o = 1'b1;
    end
  end

  assign victim_req_fire = victim_req_valid_o && victim_req_ready_i;
  assign refill_req_fire = refill_req_valid_o && refill_req_ready_i;

  always_comb begin
    word_write_valid_o = 1'b0;
    word_write_set_o = '0;
    word_write_way_o = '0;
    word_write_word_o = '0;
    word_write_data_o = '0;

    line_install_valid_o = 1'b0;
    line_install_set_o = '0;
    line_install_way_o = '0;
    line_install_data_o = '0;
    line_install_tag_o = '0;
    line_install_dirty_o = 1'b0;
    refill_rsp_ready_o = 1'b0;

    if (state_q == StateStoreCommit) begin
      word_write_valid_o = 1'b1;
      word_write_set_o = store_context.commit_set;
      word_write_way_o = store_context.commit_way;
      word_write_word_o = store_context.commit_word;
      word_write_data_o = store_context.commit_data;
    end else if (state_q == StateRefillWait) begin
      if (refill_rsp_valid_i && refill_rsp_error_i) begin
        refill_rsp_ready_o = 1'b1;
      end else begin
        line_install_valid_o = refill_rsp_valid_i;
        line_install_set_o = miss_context_q.set;
        line_install_way_o = miss_context_q.victim_way;
        line_install_data_o = miss_context_q.is_store ?
            merge_store_line(refill_rsp_data_i, miss_context_q.word,
                             store_context.wdata, store_context.wstrb) :
            refill_rsp_data_i;
        line_install_tag_o = miss_context_q.tag;
        line_install_dirty_o = miss_context_q.is_store;
        refill_rsp_ready_o = line_install_ready_i;
      end
    end
  end

  assign word_write_fire = word_write_valid_o && word_write_ready_i;
  assign line_install_fire =
      line_install_valid_o && line_install_ready_i;
  assign store_commit_fire =
      (state_q == StateStoreCommit) && word_write_fire;
  assign refill_rsp_fire = refill_rsp_valid_i && refill_rsp_ready_o;

  assign replacement_load_hit = lookup_response_current &&
      lookup_rsp_hit_i && !lookup_response_store;
  assign replacement_store_commit = store_commit_fire;
  assign replacement_refill_install = line_install_fire;

  always_comb begin
    replacement_update_valid_o = 1'b0;
    replacement_update_set_o = '0;
    replacement_update_way_o = '0;

    if (replacement_load_hit) begin
      replacement_update_valid_o = 1'b1;
      replacement_update_set_o =
          block_set(txn_q[lookup_rsp_txn_id_i].block_addr);
      replacement_update_way_o = lookup_rsp_hit_way_i;
    end else if (replacement_store_commit) begin
      replacement_update_valid_o = 1'b1;
      replacement_update_set_o = store_context.commit_set;
      replacement_update_way_o = store_context.commit_way;
    end else if (replacement_refill_install) begin
      replacement_update_valid_o = 1'b1;
      replacement_update_set_o = miss_context_q.set;
      replacement_update_way_o = miss_context_q.victim_way;
    end
  end

  assign store_capture = core_request_fire && core_req_i.write;
  assign store_release = store_commit_fire ||
      (refill_rsp_fire && miss_context_q.is_store);
  assign store_hit_capture = lookup_response_current &&
      lookup_rsp_hit_i && lookup_response_store;

  always_comb begin
    store_hit = '0;
    store_hit.set =
        block_set(txn_q[lookup_rsp_txn_id_i].block_addr);
    store_hit.word = txn_q[lookup_rsp_txn_id_i].word;
    store_hit.way = lookup_rsp_hit_way_i;
    store_hit.data = cache_merge_store_word(
      lookup_rsp_rdata_i, store_context.wdata, store_context.wstrb
    );
  end

  if (ReadOnly) begin : gen_no_store_context
    logic unused_store_inputs;

    assign store_context = '0;
    assign unused_store_inputs = ^{core_req_i.wdata, core_req_i.wstrb,
        store_capture, store_release, store_hit_capture, store_hit};
  end else begin : gen_store_context
    store_context_t store_context_q;

    assign store_context = store_context_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        store_context_q.active <= 1'b0;
      end else begin
        if (store_release) store_context_q.active <= 1'b0;
        if (store_capture) begin
          store_context_q.active <= 1'b1;
          store_context_q.txn_id <= tail_q;
          store_context_q.wdata <= core_req_i.wdata;
          store_context_q.wstrb <= core_req_i.wstrb;
        end
        if (store_hit_capture) begin
          store_context_q.commit_set <= store_hit.set;
          store_context_q.commit_word <= store_hit.word;
          store_context_q.commit_way <= store_hit.way;
          store_context_q.commit_data <= store_hit.data;
        end
      end
    end
  end

  // The transaction table is intentionally kept with the scheduler.  It has
  // random completion updates, replay state changes, and ordered head/tail
  // operations that may all occur in the same cycle.
  always_comb begin
    for (int unsigned txn = 0; txn < MaxOutstanding; txn++) begin
      txn_d[txn] = txn_q[txn];
    end

    if (core_response_fire) txn_d[head_q].state = TxnFree;

    if (lookup_rsp_valid_i) begin
      if (!lookup_response_current) begin
        txn_d[lookup_rsp_txn_id_i].state = TxnReplay;
      end else if (!lookup_rsp_hit_i) begin
        txn_d[lookup_rsp_txn_id_i].state = TxnMiss;
      end else if (lookup_response_store) begin
        txn_d[lookup_rsp_txn_id_i].state = TxnStoreCommit;
      end else begin
        txn_d[lookup_rsp_txn_id_i].state = TxnDone;
        txn_d[lookup_rsp_txn_id_i].rdata = lookup_rsp_rdata_i;
        txn_d[lookup_rsp_txn_id_i].error = 1'b0;
      end
    end

    if (store_commit_fire) begin
      txn_d[store_context.txn_id].state = TxnDone;
      txn_d[store_context.txn_id].rdata = '0;
      txn_d[store_context.txn_id].error = 1'b0;
    end

    if (refill_rsp_fire) begin
      txn_d[miss_context_q.owner].state = TxnDone;
      txn_d[miss_context_q.owner].rdata =
          (refill_rsp_error_i || miss_context_q.is_store) ? '0 :
          refill_rsp_data_i[
              int'(miss_context_q.word) * XLen +: XLen];
      txn_d[miss_context_q.owner].error = refill_rsp_error_i;
    end

    if (replay_lookup_valid && lookup_req_ready_i)
      txn_d[replay_ptr_q].state = TxnInflight;

    if (core_request_fire) begin
      txn_d[tail_q].state = TxnInflight;
      txn_d[tail_q].block_addr =
          core_req_i.addr[XLen-1:BlockOffsetW];
      txn_d[tail_q].word = address_word(core_req_i.addr);
      txn_d[tail_q].rdata = '0;
      txn_d[tail_q].error = 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StateRun;
      head_q <= '0;
      tail_q <= '0;
      usage_q <= '0;
      lookup_inflight_q <= '0;
      epoch_q <= 1'b0;
      replay_ptr_q <= '0;
      replay_remaining_q <= '0;
      for (int unsigned txn = 0; txn < MaxOutstanding; txn++) begin
        txn_q[txn].state <= TxnFree;
      end
    end else begin
      state_q <= state_d;
      for (int unsigned txn = 0; txn < MaxOutstanding; txn++) begin
        txn_q[txn] <= txn_d[txn];
      end

      if (core_response_fire) head_q <= next_txn_id(head_q);
      if (core_request_fire) tail_q <= next_txn_id(tail_q);
      unique case ({core_request_fire, core_response_fire})
        2'b10: usage_q <= usage_q + txn_count_t'(1);
        2'b01: usage_q <= usage_q - txn_count_t'(1);
        default: ;
      endcase

      unique case ({lookup_req_fire, lookup_rsp_valid_i})
        2'b10: lookup_inflight_q <=
            lookup_inflight_q + txn_count_t'(1);
        2'b01: lookup_inflight_q <=
            lookup_inflight_q - txn_count_t'(1);
        default: ;
      endcase

      if (lookup_response_miss) begin
        epoch_q <= !epoch_q;
        miss_context_q.owner <= lookup_rsp_txn_id_i;
        miss_context_q.block_addr <=
            txn_q[lookup_rsp_txn_id_i].block_addr;
        miss_context_q.set <=
            block_set(txn_q[lookup_rsp_txn_id_i].block_addr);
        miss_context_q.word <= txn_q[lookup_rsp_txn_id_i].word;
        miss_context_q.tag <=
            block_tag(txn_q[lookup_rsp_txn_id_i].block_addr);
        miss_context_q.victim_way <= lookup_rsp_victim_way_i;
        miss_context_q.victim_tag <= lookup_rsp_victim_tag_i;
        miss_context_q.victim_dirty <=
            lookup_rsp_victim_valid_i && lookup_rsp_victim_dirty_i;
        miss_context_q.is_store <= lookup_response_store;
        miss_context_q.victim_req_sent <= 1'b0;
        replay_ptr_q <= next_txn_id(lookup_rsp_txn_id_i);
        replay_remaining_q <= miss_younger_count;
      end else begin
        if (victim_req_fire)
          miss_context_q.victim_req_sent <= 1'b1;
        if (refill_req_fire)
          miss_context_q.victim_req_sent <= 1'b0;

        if (state_q == StateReplay && lookup_req_fire) begin
          replay_ptr_q <= next_txn_id(replay_ptr_q);
          replay_remaining_q <=
              replay_remaining_q - txn_count_t'(1);
        end
      end
    end
  end

  // verilog_format: off
  `ASSERT(CacheCoreResponseStable,
          core_resp_o.rsp_valid && !core_req_i.rsp_ready |=>
              $stable({core_resp_o.rsp_valid, core_resp_o.rdata,
                       core_resp_o.error}),
          clk_i, !rst_ni,
          "CoreBus response payload must remain stable while backpressured.")
  `ASSERT(CacheControlLookupRequestStable,
          lookup_req_valid_o && !lookup_req_ready_i |=>
              $stable({lookup_req_valid_o, lookup_req_txn_id_o,
                       lookup_req_epoch_o, lookup_req_set_o, lookup_req_tag_o,
                       lookup_req_word_o}),
          clk_i, !rst_ni,
          "Lookup request payload must remain stable while backpressured.")
  `ASSERT(CacheControlVictimRequestStable,
          victim_req_valid_o && !victim_req_ready_i |=>
              $stable({victim_req_valid_o, victim_req_set_o,
                       victim_req_way_o}),
          clk_i, !rst_ni,
          "Victim request payload must remain stable while backpressured.")
  `ASSERT(CacheControlWordWriteStable,
          word_write_valid_o && !word_write_ready_i |=>
              $stable({word_write_valid_o, word_write_set_o,
                       word_write_way_o, word_write_word_o,
                       word_write_data_o}),
          clk_i, !rst_ni,
          "Word write payload must remain stable while backpressured.")
  `ASSERT(CacheControlLineInstallStable,
          line_install_valid_o && !line_install_ready_i |=>
              $stable({line_install_valid_o, line_install_set_o,
                       line_install_way_o, line_install_data_o,
                       line_install_tag_o, line_install_dirty_o}),
          clk_i, !rst_ni,
          "Line install payload must remain stable while backpressured.")
  `ASSERT(CacheControlArrayWritesExclusive,
          !(word_write_valid_o && line_install_valid_o),
          clk_i, !rst_ni,
          "Word write and line install requests must be exclusive.")
  `ASSERT(CacheControlRefillRequestStable,
          refill_req_valid_o && !refill_req_ready_i |=>
              $stable({refill_req_valid_o, refill_req_block_addr_o,
                       refill_req_writeback_valid_o,
                       refill_req_writeback_block_addr_o,
                       refill_req_writeback_data_o}),
          clk_i, !rst_ni,
          "Refill request payload must remain stable while backpressured.")
  `ASSERT(CacheTransactionCountValid,
          usage_q <= txn_count_t'(MaxOutstanding),
          clk_i, !rst_ni,
          "Cache transaction usage must not exceed MaxOutstanding.")
  `ASSERT(CacheLookupCountValid,
          lookup_inflight_q <= txn_count_t'(MaxOutstanding),
          clk_i, !rst_ni,
          "Lookup pipeline occupancy must be covered by transaction credits.")
  `ASSERT(CacheLookupResponseExpected,
          lookup_rsp_valid_i |->
              (txn_q[lookup_rsp_txn_id_i].state == TxnInflight),
          clk_i, !rst_ni,
          "Every array response must identify an in-flight transaction.")
  `ASSERT(CacheReplacementUpdateCommitted,
          replacement_update_valid_o |->
              (replacement_load_hit || replacement_store_commit ||
               replacement_refill_install),
          clk_i, !rst_ni,
          "Replacement state may update only for a committed cache access.")
  `ASSERT(CacheStoreWaitsForOlderLookups,
          core_request_fire && core_req_i.write |->
              (lookup_inflight_q == '0),
          clk_i, !rst_ni,
          "A store may issue only after all older lookups have resolved.")
  `ASSERT(CacheCoreRequestSizeValid,
          core_req_i.req_valid |-> (core_req_i.size <= CORE_BUS_SIZE_WORD),
          clk_i, !rst_ni,
          "Cache requests support byte, halfword, and word accesses.")
  `ASSERT(CacheCoreRequestAligned,
          core_req_i.req_valid |->
              ((core_req_i.size == CORE_BUS_SIZE_BYTE) ||
               ((core_req_i.size == CORE_BUS_SIZE_HALF) && !core_req_i.addr[0]) ||
               ((core_req_i.size == CORE_BUS_SIZE_WORD) &&
                (core_req_i.addr[1:0] == '0))),
          clk_i, !rst_ni,
          "Cache requests must be naturally aligned.")
  `ASSERT(CacheCoreRequestStrobeValid,
          core_req_i.req_valid |->
              (core_req_i.write ?
                   (core_req_i.wstrb ==
                    expected_store_strobe(core_req_i.addr,
                                          core_req_i.size)) :
                   (core_req_i.wstrb == '0)),
          clk_i, !rst_ni,
          "CoreBus byte strobes must match the request address and size.")
  `ASSERT(CacheReplayEntryExpected,
          replay_lookup_valid |->
              (txn_q[replay_ptr_q].state == TxnReplay),
          clk_i, !rst_ni,
          "Replay scheduling must select a transaction marked for replay.")
  // verilog_format: on

  if (ReadOnly) begin : gen_read_only_assertions
    `ASSERT(CacheControlReadOnlyRequest,
            core_req_i.req_valid |-> !core_req_i.write,
            clk_i, !rst_ni,
            "A read-only cache control plane must never receive a write request.")
    `ASSERT(CacheControlReadOnlyWriteback,
            !refill_req_writeback_valid_o,
            clk_i, !rst_ni,
            "A read-only cache control plane must never request a writeback.")
  end

endmodule
