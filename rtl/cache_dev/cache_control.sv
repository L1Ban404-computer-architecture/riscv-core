// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 顺序 Cache 控制面。
//
// 管理 CoreBus 请求准入、事务表和响应保序，调度阵列查询、store 提交、牺牲行
// 读取、AXI 行写回/读取、缓存行安装和 miss 后重放。
// CoreBus 仅由事务表队首完成；任一时刻最多保留一个 store 和一个 miss 上下文；
// store 必须等待更老查询完成；miss 期间用 epoch 过滤旧响应并重放年轻事务。
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
  localparam int unsigned WordIndexW = (WordCount > 1) ? $clog2(WordCount) : 1,
  localparam int unsigned WayIndexW = (WayCount > 1) ? $clog2(WayCount) : 1,
  localparam int unsigned TxnIdW = (MaxOutstanding > 1) ? $clog2(MaxOutstanding) : 1,
  localparam int unsigned LineBits = BlockBytes * ByteW
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // CoreBus 事务
  core_bus_if.slave core_bus,

  // Cache 维护排空状态
  input logic quiesce_request,
  output logic quiesce_idle,

  // 阵列事务
  array_lookup_if.requester lookup,
  array_victim_if.requester victim,
  array_word_write_if.producer word_write,
  array_line_install_if.producer line_install,

  // AXI 缓存行事务
  axi_line_read_if.requester line_read,
  axi_line_write_if.requester line_write
);

  ////////////////////////////////
  // 私有类型、事务表与调度状态 //
  ////////////////////////////////

  localparam int unsigned TxnCountW = (MaxOutstanding > 1) ? $clog2(MaxOutstanding + 1) : 1;

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
    StateWritebackWait,
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
    way_index_t way;
    word_t data;
  } store_hit_t;

  typedef struct packed {
    logic active;
    txn_id_t txn_id;
    word_t wdata;
    byte_en_t wstrb;
    way_index_t commit_way;
    word_t commit_data;
  } store_context_t;

  typedef struct packed {
    txn_id_t owner;
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
  block_addr_t store_block_addr;
  word_index_t store_word;
  block_addr_t miss_block_addr;
  word_index_t miss_word;

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
  logic line_read_req_fire;
  logic line_read_rsp_fire;
  logic line_write_req_fire;
  logic line_write_rsp_fire;
  logic miss_complete_fire;
  logic word_write_fire;
  logic store_commit_fire;

  logic store_capture;
  logic store_release;
  logic store_hit_capture;
  store_hit_t store_hit;
  logic [LineBits-1:0] store_hit_line;

  txn_count_t existing_younger_count;
  txn_count_t miss_younger_count;
  txn_id_t next_miss_owner;

  // 上下文只保存事务 ID；地址和 word 从事务表中选择，避免重复寄存。
  assign store_block_addr = txn_q[store_context.txn_id].block_addr;
  assign store_word = txn_q[store_context.txn_id].word;
  assign miss_block_addr = txn_q[miss_context_q.owner].block_addr;
  assign miss_word = txn_q[miss_context_q.owner].word;

  ////////////////////////
  // 地址与事务辅助函数 //
  ////////////////////////

  function automatic txn_id_t next_txn_id(input txn_id_t id);
    if (id == txn_id_t'(MaxOutstanding - 1)) return '0;
    return id + txn_id_t'(1);
  endfunction

  function automatic txn_count_t queue_distance(input txn_id_t from, input txn_id_t to);
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

  function automatic block_addr_t victim_block_addr(input tag_t tag, input set_index_t set);
    block_addr_t result;

    result = BlockAddrW'(tag);
    result = result << SetIndexBits;
    if (SetCount > 1) result |= BlockAddrW'(set);
    return result;
  endfunction

  function automatic logic [LineBits-1:0] merge_store_line(
      input logic [LineBits-1:0] old_line, input word_index_t word_index, input word_t new_word,
      input byte_en_t strobe);
    logic [LineBits-1:0] updated_line;
    word_t old_word;
    word_t byte_mask;

    updated_line = old_line;
    old_word = old_line[int'(word_index)*XLen+:XLen];
    byte_mask = '0;
    for (int unsigned lane = 0; lane < StrbW; lane++) begin
      byte_mask[lane*ByteW+:ByteW] = {ByteW{strobe[lane]}};
    end
    updated_line[int'(word_index)*XLen+:XLen] = (old_word & ~byte_mask) | (new_word & byte_mask);
    return updated_line;
  endfunction

  // 根据 CoreBus 地址和传输宽度生成写请求应携带的 byte strobe。该函数只服务于
  // 本模块的协议 assertion，因此与 CoreBus 类型一起保留在总线边界内部。
  function automatic byte_en_t expected_store_strobe(input word_t address,
                                                     input core_bus_size_e size);
    byte_en_t base_strobe;

    unique case (size)
      CORE_BUS_SIZE_BYTE: base_strobe = byte_en_t'(1);
      CORE_BUS_SIZE_HALF: base_strobe = byte_en_t'(3);
      CORE_BUS_SIZE_WORD: base_strobe = '1;
      default: base_strobe = '0;
    endcase
    return byte_en_t'(base_strobe << int'(address % StrbW));
  endfunction

  //////////////////////////////////////
  // CoreBus 准入、保序响应与查询调度 //
  //////////////////////////////////////

  // CoreBus 只允许由顺序事务表的队首产生完成响应，确保内部乱序完成不会改变外部顺序。
  assign core_bus.rsp_valid = (usage_q != '0) && (txn_q[head_q].state == TxnDone);
  assign core_bus.rsp_payload.rdata = txn_q[head_q].rdata;
  assign core_bus.rsp_payload.error = txn_q[head_q].error;
  assign core_response_fire = core_bus.rsp_valid && core_bus.rsp_ready;

  assign queue_credit = (usage_q < txn_count_t'(MaxOutstanding)) || core_response_fire;
  assign direct_lookup_allowed = (state_q == StateRun) && !quiesce_request &&
      !store_context.active && queue_credit && (!ReadOnly || !core_bus.req_payload.write) &&
      (!core_bus.req_payload.write || (lookup_inflight_q == '0));
  assign direct_lookup_valid = direct_lookup_allowed && core_bus.req_valid;
  assign replay_lookup_valid = (state_q == StateReplay) && (replay_remaining_q != '0);

  always_comb begin
    lookup.req_valid = 1'b0;
    lookup.req_payload = '0;
    lookup.req_payload.epoch = epoch_q;

    if (replay_lookup_valid) begin
      lookup.req_valid = 1'b1;
      lookup.req_payload.txn_id = replay_ptr_q;
      lookup.req_payload.set = block_set(txn_q[replay_ptr_q].block_addr);
      lookup.req_payload.tag = block_tag(txn_q[replay_ptr_q].block_addr);
      lookup.req_payload.word = txn_q[replay_ptr_q].word;
    end else if (direct_lookup_valid) begin
      lookup.req_valid = 1'b1;
      lookup.req_payload.txn_id = tail_q;
      lookup.req_payload.set = block_set(core_bus.req_payload.addr[XLen-1:BlockOffsetW]);
      lookup.req_payload.tag = block_tag(core_bus.req_payload.addr[XLen-1:BlockOffsetW]);
      lookup.req_payload.word = address_word(core_bus.req_payload.addr);
    end
  end

  assign core_bus.req_ready = direct_lookup_allowed && lookup.req_ready;
  assign core_request_fire = core_bus.req_valid && core_bus.req_ready;
  assign lookup_req_fire = lookup.req_valid && lookup.req_ready;

  // 维护扫描只在全部既有 CoreBus 事务完成响应、控制状态恢复运行且 lookup/store
  // 上下文均为空后获得 array 和 line AXI engine 的所有权。
  assign quiesce_idle = (state_q == StateRun) && (usage_q == '0) && (lookup_inflight_q == '0) &&
      !store_context.active;

  assign lookup_response_current = lookup.rsp_valid && (lookup.rsp_payload.epoch == epoch_q);
  assign lookup_response_store = store_context.active &&
      (store_context.txn_id == lookup.rsp_payload.txn_id);
  assign lookup_response_miss = lookup_response_current && !lookup.rsp_payload.hit;

  assign next_miss_owner = lookup.rsp_payload.txn_id;
  assign existing_younger_count = queue_distance(next_txn_id(next_miss_owner), tail_q);
  assign miss_younger_count = existing_younger_count + txn_count_t'(core_request_fire);

  ////////////////////////////
  // Miss、回填与重放状态机 //
  ////////////////////////////

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
        if (line_write_req_fire) state_d = StateWritebackWait;
      end

      StateWritebackWait: begin
        if (line_write_rsp_fire) begin
          if (line_write.rsp_payload.error) begin
            if (replay_remaining_q != '0) state_d = StateReplay;
            else state_d = StateRun;
          end else begin
            state_d = StateRefillRequest;
          end
        end
      end

      StateRefillRequest: begin
        if (line_read_req_fire) state_d = StateRefillWait;
      end

      StateRefillWait: begin
        if (line_read_rsp_fire) begin
          if (replay_remaining_q != '0) state_d = StateReplay;
          else state_d = StateRun;
        end
      end

      StateReplay: begin
        if (lookup_req_fire && (replay_remaining_q == txn_count_t'(1))) state_d = StateRun;
      end

      default: state_d = StateRun;
    endcase

    if (lookup_response_current) begin
      if (lookup_response_miss) state_d = StateMissDrain;
      else if (lookup_response_store) state_d = StateStoreCommit;
    end
  end

  // 脏牺牲行从阵列响应直接进入 line-write 请求；控制面不设置第二份缓存行
  // 缓冲区，因此两个握手必须在同拍发生。写回成功后才单独发起 line-read。
  always_comb begin
    victim.req_valid = 1'b0;
    victim.req_payload.set = block_set(miss_block_addr);
    victim.req_payload.way = miss_context_q.victim_way;
    victim.rsp_ready = 1'b0;

    line_write.req_valid = 1'b0;
    line_write.req_payload.block_addr =
        victim_block_addr(miss_context_q.victim_tag, block_set(miss_block_addr));
    line_write.req_payload.line = victim.rsp_payload.line;
    line_write.rsp_ready = state_q == StateWritebackWait;

    line_read.req_valid = state_q == StateRefillRequest;
    line_read.req_payload.block_addr = miss_block_addr;

    if (state_q == StateVictimRead) begin
      victim.req_valid = !miss_context_q.victim_req_sent;
      line_write.req_valid = victim.rsp_valid;
      victim.rsp_ready = line_write.req_ready;
    end
  end

  assign victim_req_fire = victim.req_valid && victim.req_ready;
  assign line_write_req_fire = line_write.req_valid && line_write.req_ready;
  assign line_write_rsp_fire = line_write.rsp_valid && line_write.rsp_ready;
  assign line_read_req_fire = line_read.req_valid && line_read.req_ready;
  assign line_read_rsp_fire = line_read.rsp_valid && line_read.rsp_ready;
  assign miss_complete_fire = (line_write_rsp_fire && line_write.rsp_payload.error) ||
      line_read_rsp_fire;

  ////////////////////////////
  // Store 提交与缓存行安装 //
  ////////////////////////////

  always_comb begin
    word_write.valid = 1'b0;
    word_write.payload = '0;

    line_install.valid = 1'b0;
    line_install.payload = '0;
    line_read.rsp_ready = 1'b0;

    if (state_q == StateStoreCommit) begin
      word_write.valid = 1'b1;
      word_write.payload.set = block_set(store_block_addr);
      word_write.payload.way = store_context.commit_way;
      word_write.payload.word = store_word;
      word_write.payload.data = store_context.commit_data;
    end else if (state_q == StateRefillWait) begin
      if (line_read.rsp_valid && line_read.rsp_payload.error) begin
        line_read.rsp_ready = 1'b1;
      end else begin
        line_install.valid = line_read.rsp_valid;
        line_install.payload.set = block_set(miss_block_addr);
        line_install.payload.way = miss_context_q.victim_way;
        line_install.payload.data = miss_context_q.is_store ?
            merge_store_line(line_read.rsp_payload.line, miss_word, store_context.wdata,
                             store_context.wstrb) : line_read.rsp_payload.line;
        line_install.payload.tag = block_tag(miss_block_addr);
        line_install.payload.dirty = miss_context_q.is_store;
        line_read.rsp_ready = line_install.ready;
      end
    end
  end

  assign word_write_fire = word_write.valid && word_write.ready;
  assign store_commit_fire = (state_q == StateStoreCommit) && word_write_fire;
  assign store_capture = core_request_fire && core_bus.req_payload.write;
  assign store_release = store_commit_fire || (miss_complete_fire && miss_context_q.is_store);
  assign store_hit_capture = lookup_response_current && lookup.rsp_payload.hit &&
      lookup_response_store;

  //////////////////
  // Store 上下文 //
  //////////////////

  always_comb begin
    store_hit = '0;
    store_hit_line = '0;
    store_hit.way = lookup.rsp_payload.hit_way;
    store_hit_line[int'(store_word)*XLen+:XLen] = lookup.rsp_payload.rdata;
    store_hit_line =
        merge_store_line(store_hit_line, store_word, store_context.wdata, store_context.wstrb);
    store_hit.data = store_hit_line[int'(store_word)*XLen+:XLen];
  end

  if (ReadOnly) begin : gen_no_store_context
    logic unused_store_inputs;

    assign store_context = '0;
    assign unused_store_inputs = ^{core_bus.req_payload.wdata, core_bus.req_payload.wstrb,
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
          store_context_q.wdata <= core_bus.req_payload.wdata;
          store_context_q.wstrb <= core_bus.req_payload.wstrb;
        end
        if (store_hit_capture) begin
          store_context_q.commit_way <= store_hit.way;
          store_context_q.commit_data <= store_hit.data;
        end
      end
    end
  end

  ////////////////////
  // 事务表组合更新 //
  ////////////////////

  // 事务表与调度器放在同一时序块中维护，因为随机位置的完成更新、重放状态变化以及
  // 有序队首/队尾操作可能同拍发生；集中计算可明确冲突优先级并避免多处驱动。
  always_comb begin
    for (int unsigned txn = 0; txn < MaxOutstanding; txn++) begin
      txn_d[txn] = txn_q[txn];
    end

    if (core_response_fire) txn_d[head_q].state = TxnFree;

    if (lookup.rsp_valid) begin
      if (!lookup_response_current) begin
        txn_d[lookup.rsp_payload.txn_id].state = TxnReplay;
      end else if (!lookup.rsp_payload.hit) begin
        txn_d[lookup.rsp_payload.txn_id].state = TxnMiss;
      end else if (lookup_response_store) begin
        txn_d[lookup.rsp_payload.txn_id].state = TxnStoreCommit;
      end else begin
        txn_d[lookup.rsp_payload.txn_id].state = TxnDone;
        txn_d[lookup.rsp_payload.txn_id].rdata = lookup.rsp_payload.rdata;
        txn_d[lookup.rsp_payload.txn_id].error = 1'b0;
      end
    end

    if (store_commit_fire) begin
      txn_d[store_context.txn_id].state = TxnDone;
      txn_d[store_context.txn_id].rdata = '0;
      txn_d[store_context.txn_id].error = 1'b0;
    end

    if (miss_complete_fire) begin
      txn_d[miss_context_q.owner].state = TxnDone;
      if (line_write_rsp_fire) begin
        txn_d[miss_context_q.owner].rdata = '0;
        txn_d[miss_context_q.owner].error = 1'b1;
      end else begin
        txn_d[miss_context_q.owner].rdata = (line_read.rsp_payload.error || miss_context_q.is_store)
            ? '0 : line_read.rsp_payload.line[int'(miss_word)*XLen+:XLen];
        txn_d[miss_context_q.owner].error = line_read.rsp_payload.error;
      end
    end

    if (replay_lookup_valid && lookup.req_ready) txn_d[replay_ptr_q].state = TxnInflight;

    if (core_request_fire) begin
      txn_d[tail_q].state = TxnInflight;
      txn_d[tail_q].block_addr = core_bus.req_payload.addr[XLen-1:BlockOffsetW];
      txn_d[tail_q].word = address_word(core_bus.req_payload.addr);
      txn_d[tail_q].rdata = '0;
      txn_d[tail_q].error = 1'b0;
    end
  end

  //////////////////////////
  // 调度状态与事务表寄存 //
  //////////////////////////

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
      unique case ({
        core_request_fire, core_response_fire
      })
        2'b10: usage_q <= usage_q + txn_count_t'(1);
        2'b01: usage_q <= usage_q - txn_count_t'(1);
        default: ;
      endcase

      unique case ({
        lookup_req_fire, lookup.rsp_valid
      })
        2'b10: lookup_inflight_q <= lookup_inflight_q + txn_count_t'(1);
        2'b01: lookup_inflight_q <= lookup_inflight_q - txn_count_t'(1);
        default: ;
      endcase

      if (lookup_response_miss) begin
        epoch_q <= !epoch_q;
        miss_context_q.owner <= lookup.rsp_payload.txn_id;
        miss_context_q.victim_way <= lookup.rsp_payload.victim_way;
        miss_context_q.victim_tag <= lookup.rsp_payload.victim_tag;
        miss_context_q.victim_dirty <= lookup.rsp_payload.victim_valid &&
            lookup.rsp_payload.victim_dirty;
        miss_context_q.is_store <= lookup_response_store;
        miss_context_q.victim_req_sent <= 1'b0;
        replay_ptr_q <= next_txn_id(lookup.rsp_payload.txn_id);
        replay_remaining_q <= miss_younger_count;
      end else begin
        if (victim_req_fire) miss_context_q.victim_req_sent <= 1'b1;
        if (line_write_req_fire) miss_context_q.victim_req_sent <= 1'b0;

        if (state_q == StateReplay && lookup_req_fire) begin
          replay_ptr_q <= next_txn_id(replay_ptr_q);
          replay_remaining_q <= replay_remaining_q - txn_count_t'(1);
        end
      end
    end
  end

  ////////////////////
  // 协议与参数断言 //
  ////////////////////

  // verilog_format: off
  `ASSERT_INIT(CacheControlInterfaceWidths,
               $bits(core_bus.req_payload.addr) == XLen &&
                   $bits(core_bus.req_payload.wdata) == XLen &&
                   $bits(lookup.req_payload.txn_id) == TxnIdW &&
                   $bits(lookup.req_payload.set) == SetIndexW &&
                   $bits(lookup.req_payload.tag) == TagW &&
                   $bits(lookup.req_payload.word) == WordIndexW &&
                   $bits(lookup.rsp_payload.hit_way) == WayIndexW &&
                   $bits(victim.req_payload.set) == SetIndexW &&
                   $bits(victim.req_payload.way) == WayIndexW &&
                   $bits(victim.rsp_payload.line) == LineBits &&
                   $bits(word_write.payload.data) == XLen &&
                   $bits(line_install.payload.data) == LineBits &&
                   $bits(line_read.req_payload.block_addr) == BlockAddrW &&
                   $bits(line_read.rsp_payload.line) == LineBits &&
                   $bits(line_write.req_payload.block_addr) == BlockAddrW &&
                   $bits(line_write.req_payload.line) == LineBits,
               "Cache control geometry must match every connected interface.")
  `ASSERT(CacheCoreResponseStable,
          core_bus.rsp_valid && !core_bus.rsp_ready |=>
              $stable({core_bus.rsp_valid, core_bus.rsp_payload}),
          clk_i, !rst_ni,
          "CoreBus response payload must remain stable while backpressured.")
  `ASSERT(CacheControlLookupRequestStable,
          lookup.req_valid && !lookup.req_ready |=>
              $stable({lookup.req_valid, lookup.req_payload}),
          clk_i, !rst_ni,
          "Lookup request payload must remain stable while backpressured.")
  `ASSERT(CacheControlVictimRequestStable,
          victim.req_valid && !victim.req_ready |=>
              $stable({victim.req_valid, victim.req_payload}),
          clk_i, !rst_ni,
          "Victim request payload must remain stable while backpressured.")
  `ASSERT(CacheControlWordWriteStable,
          word_write.valid && !word_write.ready |=>
              $stable({word_write.valid, word_write.payload}),
          clk_i, !rst_ni,
          "Word write payload must remain stable while backpressured.")
  `ASSERT(CacheControlLineInstallStable,
          line_install.valid && !line_install.ready |=>
              $stable({line_install.valid, line_install.payload}),
          clk_i, !rst_ni,
          "Line install payload must remain stable while backpressured.")
  `ASSERT(CacheControlArrayWritesExclusive,
          !(word_write.valid && line_install.valid),
          clk_i, !rst_ni,
          "Word write and line install requests must be exclusive.")
  `ASSERT(CacheControlLineReadRequestStable,
          line_read.req_valid && !line_read.req_ready |=>
              $stable({line_read.req_valid, line_read.req_payload}),
          clk_i, !rst_ni,
          "Line-read request must remain stable while backpressured.")
  `ASSERT(CacheControlLineWriteRequestStable,
          line_write.req_valid && !line_write.req_ready |=>
              $stable({line_write.req_valid, line_write.req_payload}),
          clk_i, !rst_ni,
          "Line-write request must remain stable while backpressured.")
  `ASSERT(CacheControlLineRequestsExclusive,
          !(line_read.req_valid && line_write.req_valid),
          clk_i, !rst_ni,
          "The blocking miss sequence must not request line read and write together.")
  `ASSERT(CacheControlLineReadResponseExpected,
          line_read.rsp_valid |-> (state_q == StateRefillWait),
          clk_i, !rst_ni,
          "A line-read response is legal only while a refill is outstanding.")
  `ASSERT(CacheControlLineWriteResponseExpected,
          line_write.rsp_valid |-> (state_q == StateWritebackWait),
          clk_i, !rst_ni,
          "A line-write response is legal only while a victim writeback is outstanding.")
  `ASSERT(CacheTransactionCountValid,
          usage_q <= txn_count_t'(MaxOutstanding),
          clk_i, !rst_ni,
          "Cache transaction usage must not exceed MaxOutstanding.")
  `ASSERT(CacheLookupCountValid,
          lookup_inflight_q <= txn_count_t'(MaxOutstanding),
          clk_i, !rst_ni,
          "Lookup pipeline occupancy must be covered by transaction credits.")
  `ASSERT(CacheLookupResponseExpected,
          lookup.rsp_valid |->
              (txn_q[lookup.rsp_payload.txn_id].state == TxnInflight),
          clk_i, !rst_ni,
          "Every array response must identify an in-flight transaction.")
  `ASSERT(CacheStoreWaitsForOlderLookups,
          core_request_fire && core_bus.req_payload.write |->
              (lookup_inflight_q == '0),
          clk_i, !rst_ni,
          "A store may issue only after all older lookups have resolved.")
  `ASSERT(CacheControlQuiesceBlocksRequests,
          quiesce_request |-> !core_request_fire,
          clk_i, !rst_ni,
          "A pending maintenance request must block new CoreBus requests.")
  `ASSERT(CacheControlQuiesceIdleSafe,
          quiesce_idle |->
              ((state_q == StateRun) && (usage_q == '0) &&
               (lookup_inflight_q == '0) && !store_context.active),
          clk_i, !rst_ni,
          "The control plane may acknowledge quiesce only after fully draining.")
  `ASSERT(CacheCoreRequestSizeValid,
          core_bus.req_valid |->
              (core_bus.req_payload.size <= CORE_BUS_SIZE_WORD),
          clk_i, !rst_ni,
          "Cache requests support byte, halfword, and word accesses.")
  `ASSERT(CacheCoreRequestAligned,
          core_bus.req_valid |->
              ((core_bus.req_payload.size == CORE_BUS_SIZE_BYTE) ||
               ((core_bus.req_payload.size == CORE_BUS_SIZE_HALF) &&
                !core_bus.req_payload.addr[0]) ||
               ((core_bus.req_payload.size == CORE_BUS_SIZE_WORD) &&
                (core_bus.req_payload.addr[1:0] == '0))),
          clk_i, !rst_ni,
          "Cache requests must be naturally aligned.")
  `ASSERT(CacheCoreRequestStrobeValid,
          core_bus.req_valid |->
              (core_bus.req_payload.write ?
                   (core_bus.req_payload.wstrb ==
                    expected_store_strobe(core_bus.req_payload.addr,
                                          core_bus.req_payload.size)) :
                   (core_bus.req_payload.wstrb == '0)),
          clk_i, !rst_ni,
          "CoreBus byte strobes must match the request address and size.")
  `ASSERT(CacheReplayEntryExpected,
          replay_lookup_valid |->
              (txn_q[replay_ptr_q].state == TxnReplay),
          clk_i, !rst_ni,
          "Replay scheduling must select a transaction marked for replay.")
  // verilog_format: on

  if (ReadOnly) begin : gen_read_only_assertions
    `ASSERT(CacheControlReadOnlyRequest, core_bus.req_valid |-> !core_bus.req_payload.write, clk_i,
            !rst_ni, "A read-only cache control plane must never receive a write request.")
    `ASSERT(CacheControlReadOnlyWriteback, !line_write.req_valid, clk_i, !rst_ni,
            "A read-only cache control plane must never request a writeback.")
  end

endmodule
