// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 超小型 I-cache 寄存器阵列。
//
// tag、valid 和所有指令 word 均使用寄存器保存。查询同时比较目标组内所有路，
// 命中数据在同一组合路径返回。refill 开始时先使牺牲路无效并写入新 tag，随后
// 每个 AXI R beat 直接写目标 word；只有完整且无错误的 burst 才重新置 valid。
`include "common/assertions.svh"

module icache_array
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned BlockBytes = 4,
  parameter int unsigned SetCount = 2,
  parameter int unsigned WayCount = 2,
  parameter icache_replacement_policy_e ReplacementPolicy = ICACHE_REPLACEMENT_ROUND_ROBIN,
  localparam int unsigned BlockOffsetW = $clog2(BlockBytes),
  localparam int unsigned SetIndexBits = $clog2(SetCount),
  localparam int unsigned SetIndexW = (SetCount > 1) ? SetIndexBits : 1,
  localparam int unsigned TagW = AddrWidth - BlockOffsetW - SetIndexBits,
  localparam int unsigned WordCount = BlockBytes / (DataWidth / 8),
  localparam int unsigned WordIndexW = (WordCount > 1) ? $clog2(WordCount) : 1,
  localparam int unsigned WayIndexW = (WayCount > 1) ? $clog2(WayCount) : 1
) (
  // 全局控制与全阵列失效提交
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_apply_i,

  // 控制器查询与回填事务
  icache_lookup_if.array lookup,
  icache_refill_if.array refill
);

  //////////////////////
  // 私有类型与寄存器阵列 //
  //////////////////////

  typedef logic [SetIndexW-1:0] set_index_t;
  typedef logic [WayIndexW-1:0] way_index_t;
  typedef logic [WordIndexW-1:0] word_index_t;
  typedef logic [TagW-1:0] tag_t;

  // 物理组织为 [路][组][行内 word]；默认数据阵列总计 2 * 2 * 1 * 32 = 128 bit。
  // data 和 tag 不复位，valid=0 时其内容不可见，从而节省复位网络。
  logic [DataWidth-1:0] data_q[WayCount][SetCount][WordCount];
  tag_t tag_q[WayCount][SetCount];
  logic valid_q[WayCount][SetCount];

  set_index_t lookup_set;
  word_index_t lookup_word;
  tag_t lookup_tag;
  set_index_t refill_begin_set;
  tag_t refill_begin_tag;
  logic [WayCount-1:0] lookup_valid_vector;
  logic [WayCount-1:0] lookup_hit_vector;
  way_index_t lookup_hit_way;

  ////////////////////
  // 地址拆分辅助函数 //
  ////////////////////

  // 地址布局为 {tag, set, line offset}，line offset 内再按数据宽度选择 word。
  function automatic set_index_t set_from_addr(input logic [AddrWidth-1:0] address);
    set_index_t result;

    result = '0;
    if (SetCount > 1) result = set_index_t'(address >> BlockOffsetW);
    return result;
  endfunction

  function automatic word_index_t word_from_addr(input logic [AddrWidth-1:0] address);
    word_index_t result;

    result = '0;
    if (WordCount > 1) result = word_index_t'(address >> $clog2(DataWidth / 8));
    return result;
  endfunction

  //////////////////////
  // 组合地址译码与查询 //
  //////////////////////

  assign lookup_set = set_from_addr(lookup.req_payload.addr);
  assign lookup_word = word_from_addr(lookup.req_payload.addr);
  assign lookup_tag = tag_t'(lookup.req_payload.addr >> (BlockOffsetW + SetIndexBits));
  assign refill_begin_set = set_from_addr(refill.begin_payload.addr);
  assign refill_begin_tag =
      tag_t'(refill.begin_payload.addr >> (BlockOffsetW + SetIndexBits));
  assign refill.read_data =
      data_q[refill.read_payload.way][refill.read_payload.set][refill.read_payload.word];

  // 并行读取目标组所有 valid/tag。正常情况下至多一路命中；若元数据异常导致多路
  // 命中，数据选择仍固定取最低编号路，同时由下方 onehot0 assertion 报告错误。
  always_comb begin
    lookup.rsp_payload.hit = 1'b0;
    lookup.rsp_payload.rdata = '0;
    lookup_hit_way = '0;
    lookup_valid_vector = '0;
    lookup_hit_vector = '0;
    for (int unsigned way = 0; way < WayCount; way++) begin
      lookup_valid_vector[way] = valid_q[way][lookup_set];
      lookup_hit_vector[way] = valid_q[way][lookup_set] && (tag_q[way][lookup_set] == lookup_tag);
      if (lookup.req_valid && !lookup.rsp_payload.hit && lookup_hit_vector[way]) begin
        lookup.rsp_payload.hit = 1'b1;
        lookup_hit_way = way_index_t'(way);
        lookup.rsp_payload.rdata = data_q[way][lookup_set][lookup_word];
      end
    end
  end

  //////////////////
  // 牺牲路选择与更新 //
  //////////////////

  // hit 只在 CoreBus 原子握手时更新；fill 只在无错误回填最终提交时更新。
  icache_replacement_policy #(
    .SetCount(SetCount),
    .WayCount(WayCount),
    .ReplacementPolicy(ReplacementPolicy)
  ) u_replacement_policy (
    .clk_i,
    .rst_ni,
    .select_set_i(lookup_set),
    .select_valid_i(lookup_valid_vector),
    .victim_way_o(lookup.rsp_payload.victim_way),
    .hit_valid_i(lookup.commit),
    .hit_set_i(lookup_set),
    .hit_way_i(lookup_hit_way),
    .fill_valid_i(refill.beat_valid && refill.beat_payload.commit),
    .fill_set_i(refill.beat_payload.set),
    .fill_way_i(refill.beat_payload.way)
  );

  ////////////////////////
  // 标签、数据和有效位写入 //
  ////////////////////////

  // 优先级为全阵列失效 > refill 开始/beat/提交。控制器只会在事务排空后产生
  // invalidate_apply_i，因此正常协议下失效不会截断正在进行的 refill。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned way = 0; way < WayCount; way++) begin
        for (int unsigned set = 0; set < SetCount; set++) valid_q[way][set] <= 1'b0;
      end
    end else if (invalidate_apply_i) begin
      for (int unsigned way = 0; way < WayCount; way++) begin
        for (int unsigned set = 0; set < SetCount; set++) valid_q[way][set] <= 1'b0;
      end
    end else begin
      if (refill.begin_valid) begin
        // AR handshake 后立即占用牺牲路；回填结束前该路不可被查询命中。
        valid_q[refill.begin_payload.way][refill_begin_set] <= 1'b0;
        tag_q[refill.begin_payload.way][refill_begin_set] <= refill_begin_tag;
      end
      if (refill.beat_valid)
        // beat 数据直接落入最终位置，不构造额外的缓存行寄存器。
        data_q[refill.beat_payload.way][refill.beat_payload.set][refill.beat_payload.word] <=
            refill.beat_payload.data;
      if (refill.beat_valid && refill.beat_payload.commit)
        // commit 只可能出现在校验通过的最后一拍，原子地使整行对查询可见。
        valid_q[refill.beat_payload.way][refill.beat_payload.set] <= 1'b1;
    end
  end

  //////////////////
  // 协议与索引断言 //
  //////////////////

  `ASSERT(ICacheArrayHitUnique, $onehot0(lookup_hit_vector), clk_i, !rst_ni)
  `ASSERT(ICacheArrayRefillBeginWayValid,
          refill.begin_valid |-> (int'(refill.begin_payload.way) < WayCount), clk_i, !rst_ni)
  `ASSERT(ICacheArrayRefillIndicesValid,
          refill.beat_valid |->
              (int'(refill.beat_payload.set) < SetCount) &&
                  (int'(refill.beat_payload.way) < WayCount) &&
                  (int'(refill.beat_payload.word) < WordCount), clk_i, !rst_ni)
  for (genvar way = 0; way < WayCount; way++) begin : gen_invalidate_assertion
    for (genvar set = 0; set < SetCount; set++) begin : gen_set
      `ASSERT(ICacheArrayInvalidateClearsValid,
              invalidate_apply_i |=> !valid_q[way][set], clk_i, !rst_ni)
    end
  end

endmodule
