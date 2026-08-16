// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Cache 阵列数据通路。
//
// 保存标签、有效位、脏位和数据，完成并行标签比较、命中数据选择、牺牲路选择、
// 单字写入、整行安装和牺牲行读取。
// 原始逐路元数据不得跨出本模块；查询响应延迟固定；同拍阵列操作互斥并按
// 整行安装 > 单字写入 > 牺牲行读取 > 普通查询的顺序仲裁。
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
  localparam int unsigned WordIndexW = (WordCount > 1) ? $clog2(WordCount) : 1,
  localparam int unsigned WayIndexW = (WayCount > 1) ? $clog2(WayCount) : 1,
  localparam int unsigned TxnIdW = (MaxOutstanding > 1) ? $clog2(MaxOutstanding) : 1,
  localparam int unsigned LineBits = BlockBytes * ByteW
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 查询事务
  cache_lookup_req_if.consumer lookup_req,
  cache_lookup_rsp_if.producer lookup_rsp,

  // 阵列维护事务
  cache_victim_req_if.consumer victim_req,
  cache_victim_rsp_if.producer victim_rsp,
  cache_word_write_if.consumer word_write,
  cache_line_install_if.consumer line_install
);

  //////////////////////////////
  // 私有类型、阵列与流水状态 //
  //////////////////////////////

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
  logic word_write_fire;
  logic line_install_fire;

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
  lookup_rsp_t lookup_rsp_payload;

  logic victim_rsp_valid_q;
  logic [WayIndexW-1:0] victim_way_q;

  //////////////////
  // 阵列操作仲裁 //
  //////////////////

  // 未被接收的牺牲行响应会持续占用数据 bank。新操作按“整行安装、单字写入、
  // 牺牲行读取、普通查询”从高到低仲裁，避免同拍多写或读写目标冲突。
  assign line_install.ready = !victim_rsp_valid_q || victim_rsp.ready;
  assign word_write.ready = line_install.ready && !line_install.valid;
  assign victim_req.ready = word_write.ready && !word_write.valid;
  assign lookup_req.ready = victim_req.ready && !victim_req.valid;

  assign lookup_fire = lookup_req.valid && lookup_req.ready;
  assign victim_fire = victim_req.valid && victim_req.ready;
  assign word_write_fire = word_write.valid && word_write.ready;
  assign line_install_fire = line_install.valid && line_install.ready;
  assign bank_read_set = victim_fire ? victim_req.payload.set : lookup_req.payload.set;

  ////////////////////////////
  // 数据、标签与元数据阵列 //
  ////////////////////////////

  for (genvar way = 0; way < WayCount; way++) begin : gen_way
    for (genvar bank = 0; bank < WordCount; bank++) begin : gen_word_bank
      assign bank_read_valid[way][bank] = (lookup_fire &&
                                           (lookup_req.payload.word == WordIndexW'(bank))) ||
          (victim_fire && (victim_req.payload.way == WayIndexW'(way)));
      assign bank_write_valid[way][bank] =
          (line_install_fire && (line_install.payload.way == WayIndexW'(way))) ||
          (word_write_fire && (word_write.payload.way == WayIndexW'(way)) &&
           (word_write.payload.word == WordIndexW'(bank)));
      assign bank_write_data[way][bank] = line_install_fire ?
          line_install.payload.data[bank*XLen+:XLen] : word_write.payload.data;

      cache_data_bank #(
        .SetCount(SetCount)
      ) u_data_bank (
        .clk_i,
        .rst_ni,
        .read_valid_i(bank_read_valid[way][bank]),
        .read_set_i(bank_read_set),
        .read_data_o(bank_read_data[way][bank]),
        .write_valid_i(bank_write_valid[way][bank]),
        .write_set_i(line_install_fire ? line_install.payload.set : word_write.payload.set),
        .write_data_i(bank_write_data[way][bank])
      );
    end
  end

  if (ReadOnly) begin : gen_no_dirty_array
    assign dirty_read = '0;
  end else begin : gen_dirty_array
    logic dirty_mem[WayCount][SetCount];

    for (genvar way = 0; way < WayCount; way++) begin : gen_dirty_read
      assign dirty_read[way] = dirty_mem[way][lookup_req.payload.set];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned way = 0; way < WayCount; way++) begin
          for (int unsigned set = 0; set < SetCount; set++) begin
            dirty_mem[way][set] <= 1'b0;
          end
        end
      end else if (line_install_fire) begin
        dirty_mem[line_install.payload.way][line_install.payload.set] <= line_install.payload.dirty;
      end else if (word_write_fire) begin
        dirty_mem[word_write.payload.way][word_write.payload.set] <= 1'b1;
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
    end else if (line_install_fire) begin
      valid_mem[line_install.payload.way][line_install.payload.set] <= 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (line_install_fire)
      tag_mem[line_install.payload.way][line_install.payload.set] <= line_install.payload.tag;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) lookup_base_valid_q <= 1'b0;
    else lookup_base_valid_q <= lookup_fire;
  end

  //////////////////////
  // 固定延迟查询流水 //
  //////////////////////

  // 标签、元数据和目标 word bank 在同一请求沿读取。复位只清除 valid 状态，
  // 标签与数据内容不复位，并始终由 valid 位屏蔽其中的无效值。
  always_ff @(posedge clk_i) begin
    if (lookup_fire) begin
      lookup_req_q.txn_id <= lookup_req.payload.txn_id;
      lookup_req_q.epoch <= lookup_req.payload.epoch;
      lookup_req_q.set <= lookup_req.payload.set;
      lookup_req_q.tag <= lookup_req.payload.tag;
      lookup_req_q.word <= lookup_req.payload.word;
      for (int unsigned way = 0; way < WayCount; way++) begin
        lookup_tags_q[way] <= tag_mem[way][lookup_req.payload.set];
        lookup_valids_q[way] <= valid_mem[way][lookup_req.payload.set];
        lookup_dirty_q[way] <= dirty_read[way];
      end
    end
  end

  always_comb begin
    lookup_hit_vector = '0;
    for (int unsigned way = 0; way < WayCount; way++) begin
      lookup_hit_vector[way] = lookup_valids_q[way] && (lookup_tags_q[way] == lookup_req_q.tag);
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
    lookup_base_rsp.rdata = bank_read_data[lookup_hit_way][lookup_req_q.word];
    lookup_base_rsp.victim_way = lookup_victim_way;
    lookup_base_rsp.victim_tag = lookup_tags_q[lookup_victim_way];
    lookup_base_rsp.victim_valid = lookup_valids_q[lookup_victim_way];
    lookup_base_rsp.victim_dirty = lookup_dirty_q[lookup_victim_way];
  end

  if (LookupLatency == 1) begin : gen_one_cycle_lookup
    assign lookup_rsp.valid = lookup_base_valid_q;
    assign lookup_rsp_payload = lookup_base_rsp;
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

    assign lookup_rsp.valid = valid_q[LookupLatency-2];
    assign lookup_rsp_payload = payload_q[LookupLatency-2];
  end

  assign lookup_rsp.payload = lookup_rsp_payload;

  ////////////////
  // 牺牲行读取 //
  ////////////////

  assign victim_rsp.valid = victim_rsp_valid_q;
  always_comb begin
    victim_rsp.payload = '0;
    for (int unsigned bank = 0; bank < WordCount; bank++) begin
      victim_rsp.payload.line[bank*XLen+:XLen] = bank_read_data[victim_way_q][bank];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      victim_rsp_valid_q <= 1'b0;
      victim_way_q <= '0;
    end else begin
      if (victim_rsp_valid_q && victim_rsp.ready) victim_rsp_valid_q <= 1'b0;
      if (victim_fire) begin
        victim_rsp_valid_q <= 1'b1;
        victim_way_q <= victim_req.payload.way;
      end
    end
  end

  //////////////
  // 替换策略 //
  //////////////

  // install 提交沿同时记录新安装路，避免为替换状态再引入独立事件通道。
  cache_replacement_policy #(
    .SetCount(SetCount),
    .WayCount(WayCount)
  ) u_replacement_policy (
    .clk_i,
    .rst_ni,
    .select_set_i(lookup_req_q.set),
    .select_valid_i(lookup_valids_q),
    .victim_way_o(lookup_victim_way),
    .access_valid_i(line_install_fire),
    .access_set_i(line_install.payload.set),
    .access_way_i(line_install.payload.way)
  );

  ////////////////////
  // 协议与参数断言 //
  ////////////////////

  // verilog_format: off
  `ASSERT_INIT(CacheArrayLookupLatencyValid, LookupLatency > 0,
               "Cache lookup latency must be positive.")
  `ASSERT_INIT(CacheArrayInterfaceWidths,
               $bits(lookup_req.payload.txn_id) == TxnIdW &&
                   $bits(lookup_req.payload.set) == SetIndexW &&
                   $bits(lookup_req.payload.tag) == TagW &&
                   $bits(lookup_req.payload.word) == WordIndexW &&
                   $bits(lookup_rsp.payload.hit_way) == WayIndexW &&
                   $bits(lookup_rsp.payload.rdata) == XLen &&
                   $bits(victim_req.payload.way) == WayIndexW &&
                   $bits(victim_rsp.payload.line) == LineBits &&
                   $bits(word_write.payload.data) == XLen &&
                   $bits(line_install.payload.data) == LineBits,
               "Cache array geometry must match every connected interface.")
  `ASSERT(CacheArrayLookupResponseFixedLatency,
          lookup_rsp.valid == $past(lookup_fire, LookupLatency),
          clk_i, !rst_ni,
          "Every accepted lookup must return after exactly LookupLatency cycles.")
  `ASSERT(CacheArrayOperationsExclusive,
          $onehot0({lookup_fire, victim_fire, word_write_fire,
                    line_install_fire}),
          clk_i, !rst_ni,
          "Lookup, victim read, word write, and line install operations must be exclusive.")
  `ASSERT(CacheArrayWriteRequestsExclusive,
          !(word_write.valid && line_install.valid),
          clk_i, !rst_ni,
          "Word write and line install requests must be exclusive.")
  `ASSERT(CacheArrayLookupRequestStable,
          lookup_req.valid && !lookup_req.ready |=>
              $stable({lookup_req.valid, lookup_req.payload}),
          clk_i, !rst_ni,
          "Lookup request payload must remain stable while backpressured.")
  `ASSERT(CacheArrayVictimRequestStable,
          victim_req.valid && !victim_req.ready |=>
              $stable({victim_req.valid, victim_req.payload}),
          clk_i, !rst_ni,
          "Victim request payload must remain stable while backpressured.")
  `ASSERT(CacheArrayWordWriteStable,
          word_write.valid && !word_write.ready |=>
              $stable({word_write.valid, word_write.payload}),
          clk_i, !rst_ni,
          "Word write payload must remain stable while backpressured.")
  `ASSERT(CacheArrayLineInstallStable,
          line_install.valid && !line_install.ready |=>
              $stable({line_install.valid, line_install.payload}),
          clk_i, !rst_ni,
          "Line install payload must remain stable while backpressured.")
  `ASSERT(CacheArrayVictimResponseStable,
          victim_rsp.valid && !victim_rsp.ready |=>
              $stable({victim_rsp.valid, victim_rsp.payload}),
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
    `ASSERT(CacheArrayReadOnlyWordWrite, !word_write.valid, clk_i, !rst_ni,
            "A read-only cache may install refill lines but cannot commit stores.")
    `ASSERT(CacheArrayReadOnlyDirtyInstall, line_install.valid |-> !line_install.payload.dirty,
            clk_i, !rst_ni, "A read-only cache must install clean lines.")
  end

endmodule
