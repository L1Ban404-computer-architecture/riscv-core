// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 流水线式 I-cache 阵列。
//
// CPU 侧以 CoreBus req_slave 接受查询；组合读 `mem_1rw` 当拍得到 tag/data 并做
// 命中比较，结果经 `stream_register` 送到 `icache_lookup_if`。背压时由 stream
// 寄存器保持 payload，不再依赖读口重发或单独的 addr 锁存。
//
// 回填经 `icache_refill_if` 地址/数据双通道突发写入。地址在整次 burst 期间保持
// valid，阵列不保存地址副本，只在 last 数据握手当拍拉高 addr_ready；set/tag 由
// 组合译码得到。last 且 commit 才置有效位。约定数据首拍至少晚于地址首拍一拍，
// 故牺牲路与 line offset 在写数据前已锁存。
//
// 后端约定：miss 时同一时刻只服务该笔事务；lookup 保持背压直到 CPU 回应与
// 对应 refill 全部结束。在此约束下阵列不再处理 lookup 与 refill 的并发冲突。
`include "common/assertions.svh"

module icache_array
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = ICacheAddrWidth,
  parameter int unsigned DataWidth = ICacheDataWidth,
  parameter int unsigned BlockBytes = ICacheBlockBytes,
  parameter int unsigned SetCount = ICacheSetCount,
  parameter int unsigned WayCount = ICacheWayCount,
  parameter icache_replacement_policy_e ReplacementPolicy = ICacheReplacementPolicy,
  localparam int unsigned BlockOffsetW = $clog2(BlockBytes),
  localparam int unsigned SetIndexBits = $clog2(SetCount),
  localparam int unsigned SetIndexW = (SetCount > 1) ? SetIndexBits : 1,
  localparam int unsigned TagW = AddrWidth - BlockOffsetW - SetIndexBits,
  localparam int unsigned WordCount = BlockBytes / (DataWidth / 8),
  localparam int unsigned WordIndexW = (WordCount > 1) ? $clog2(WordCount) : 1,
  localparam int unsigned WayIndexW = (WayCount > 1) ? $clog2(WayCount) : 1,
  localparam int unsigned DataDepth = SetCount * WordCount,
  localparam int unsigned DataAddrW = (DataDepth > 1) ? $clog2(DataDepth) : 1
) (
  // 全局控制与全阵列失效提交
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_apply_i,

  // CPU 请求、读结果与回填
  core_bus_if.req_slave core_bus,
  icache_lookup_if.producer lookup,
  icache_refill_if.slave refill
);

  //////////////////////
  // 私有类型与存储阵列 //
  //////////////////////

  typedef logic [SetIndexW-1:0] set_index_t;
  typedef logic [WordIndexW-1:0] word_index_t;
  typedef logic [WayIndexW-1:0] way_index_t;
  typedef logic [TagW-1:0] tag_t;
  typedef logic [DataAddrW-1:0] data_addr_t;
  typedef struct packed {
    logic [AddrWidth-1:0] addr;
    logic [DataWidth-1:0] rdata;
    logic hit;
  } lookup_payload_t;

  // valid 需要复位和整阵列失效；存储阵列不复位，valid=0 时其内容不可见。
  logic valid_q[WayCount][SetCount];
  tag_t tag_rdata[WayCount];
  logic [DataWidth-1:0] data_rdata[WayCount];

  set_index_t lookup_set;
  tag_t lookup_tag;
  word_index_t lookup_word;
  logic [WayCount-1:0] lookup_hit_oh;
  logic lookup_hit;
  logic [DataWidth-1:0] lookup_rdata;
  lookup_payload_t lookup_push_payload;
  lookup_payload_t lookup_stream_payload;
  logic lookup_stream_ready;
  logic lookup_push;

  set_index_t refill_set;
  tag_t refill_tag;
  word_index_t refill_addr_word;
  logic [WayCount-1:0] refill_select_valid;
  way_index_t refill_victim_combo;
  way_index_t refill_way_q;
  word_index_t refill_line_offset_q;
  logic refill_way_locked_q;
  logic refill_victim_select;
  logic refill_last_fire;
  logic refill_tag_we;
  logic refill_data_we;

  ////////////////////
  // 地址拆分辅助函数 //
  ////////////////////

  // 地址布局为 {tag, set, line offset}，data 阵列按 {set, word} 线性编址。
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

  function automatic tag_t tag_from_addr(input logic [AddrWidth-1:0] address);
    return tag_t'(address >> (BlockOffsetW + SetIndexBits));
  endfunction

  function automatic data_addr_t data_addr_from(input set_index_t set, input word_index_t word);
    int unsigned index;

    index = '0;
    if (SetCount > 1) index = unsigned'(int'(set)) * WordCount;
    if (WordCount > 1) index += unsigned'(int'(word));
    return data_addr_t'(index);
  endfunction

  //////////////////////////////////////
  // Lookup：组合读 + stream_register //
  //////////////////////////////////////

  // 请求地址直通组合读口；命中结果推进 stream，背压时由寄存器保持。
  assign lookup_set = set_from_addr(core_bus.req_payload.addr);
  assign lookup_tag = tag_from_addr(core_bus.req_payload.addr);
  assign lookup_word = word_from_addr(core_bus.req_payload.addr);

  always_comb begin
    for (int unsigned way = 0; way < WayCount; way++) begin
      lookup_hit_oh[way] = core_bus.req_valid && valid_q[way][lookup_set] &&
          (tag_rdata[way] == lookup_tag);
    end
  end

  always_comb begin
    lookup_rdata = '0;
    for (int unsigned way = 0; way < WayCount; way++) begin
      lookup_rdata |= {DataWidth{lookup_hit_oh[way]}} & data_rdata[way];
    end
  end

  assign lookup_hit = |lookup_hit_oh;
  assign lookup_push_payload.addr = core_bus.req_payload.addr;
  assign lookup_push_payload.rdata = lookup_rdata;
  assign lookup_push_payload.hit = lookup_hit;
  assign core_bus.req_ready = lookup_stream_ready;
  assign lookup_push = core_bus.req_valid && lookup_stream_ready;

  stream_register #(
    .T(lookup_payload_t)
  ) u_lookup_stream (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .valid_i(core_bus.req_valid),
    .ready_o(lookup_stream_ready),
    .data_i(lookup_push_payload),
    .valid_o(lookup.valid),
    .ready_i(lookup.ready),
    .data_o(lookup_stream_payload)
  );

  assign lookup.payload = lookup_stream_payload;

  //////////////////////////
  // Refill 地址/数据双通道 //
  //////////////////////////

  // 地址保持 valid 直至 last 数据握手；不锁存地址，组合译码 set/tag/起始 word。
  // 约定：数据通道首拍 valid 比地址首拍至少晚一拍，因此 way / line_offset 在首拍
  // 数据前已锁存，写通路直接使用寄存器，无需再与组合译码结果二选一。
  assign refill_set = set_from_addr(refill.addr_payload.addr);
  assign refill_tag = tag_from_addr(refill.addr_payload.addr);
  assign refill_addr_word = word_from_addr(refill.addr_payload.addr);
  assign refill_last_fire = refill.data_fire && refill.data_payload.last;
  assign refill.addr_ready = refill_last_fire;
  assign refill.data_ready = refill.addr_valid;
  assign refill_tag_we = refill.addr_valid && refill_way_locked_q;
  assign refill_data_we = refill.data_fire;
  assign refill_victim_select = refill.addr_valid && !refill_way_locked_q;

  always_comb begin
    for (int unsigned way = 0; way < WayCount; way++)
      refill_select_valid[way] = valid_q[way][refill_set];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      refill_way_locked_q <= 1'b0;
      refill_way_q <= '0;
      refill_line_offset_q <= '0;
    end else if (refill.addr_fire) begin
      refill_way_locked_q <= 1'b0;
    end else if (refill.data_fire) begin
      refill_line_offset_q <= refill_line_offset_q + word_index_t'(1);
    end else if (refill_victim_select) begin
      refill_way_q <= refill_victim_combo;
      refill_way_locked_q <= 1'b1;
      refill_line_offset_q <= refill_addr_word;
    end
  end

  //////////////////
  // 牺牲路选择与更新 //
  //////////////////

  // 命中在推进 stream 时更新；独热向量取自当拍组合比较。
  icache_replacement_policy #(
    .SetCount(SetCount),
    .WayCount(WayCount),
    .ReplacementPolicy(ReplacementPolicy)
  ) u_replacement_policy (
    .clk_i,
    .rst_ni,
    .select_set_i(refill_set),
    .select_valid_i(refill_select_valid),
    .select_en_i(refill_victim_select),
    .victim_way_o(refill_victim_combo),
    .hit_valid_i(lookup_push && lookup_hit),
    .hit_set_i(lookup_set),
    .hit_oh_i(lookup_hit_oh)
  );

  //////////////////////
  // 每路 tag / data 存储 //
  //////////////////////

  // 组合读；读地址来自 CPU 请求，写地址来自 refill。
  for (genvar way = 0; way < WayCount; way++) begin : gen_way_mem
    logic way_refill;
    logic tag_we;
    logic data_we;

    assign way_refill = refill_way_locked_q && (refill_way_q == way_index_t'(way));
    assign tag_we = way_refill && refill_tag_we;
    assign data_we = way_refill && refill_data_we;

    mem_1rw #(
      .Width(TagW),
      .Depth(SetCount),
      .CombRead(1'b1)
    ) u_tag (
      .clk_i,
      .ren_i(1'b1),
      .raddr_i(lookup_set),
      .rdata_o(tag_rdata[way]),
      .wen_i(tag_we),
      .waddr_i(refill_set),
      .wdata_i(refill_tag)
    );

    mem_1rw #(
      .Width(DataWidth),
      .Depth(DataDepth),
      .CombRead(1'b1)
    ) u_data (
      .clk_i,
      .ren_i(1'b1),
      .raddr_i(data_addr_from(lookup_set, lookup_word)),
      .rdata_o(data_rdata[way]),
      .wen_i(data_we),
      .waddr_i(data_addr_from(refill_set, refill_line_offset_q)),
      .wdata_i(refill.data_payload.data)
    );
  end

  ////////////////////////
  // 有效位写入          //
  ////////////////////////

  // 优先级为全阵列失效 > 成功 last 提交置位 > refill 开始清零。失败的 last
  // 不置位，开始时清掉的有效位保持为 0。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned way = 0; way < WayCount; way++) begin
        for (int unsigned set = 0; set < SetCount; set++) valid_q[way][set] <= 1'b0;
      end
    end else if (invalidate_apply_i) begin
      for (int unsigned way = 0; way < WayCount; way++) begin
        for (int unsigned set = 0; set < SetCount; set++) valid_q[way][set] <= 1'b0;
      end
    end else if (refill_last_fire && refill.data_payload.commit) begin
      valid_q[refill_way_q][refill_set] <= 1'b1;
    end else if (refill_victim_select) begin
      valid_q[refill_victim_combo][refill_set] <= 1'b0;
    end
  end

  //////////////
  // 协议检查 //
  //////////////

`ifndef SYNTHESIS
  // 任意两路同时命中即为重复。1 路时内层循环不执行。
  logic hit_unique;
  always_comb begin
    hit_unique = 1'b1;
    for (int unsigned way = 0; way < WayCount; way++) begin
      for (int unsigned other = way + 1; other < WayCount; other++) begin
        if (lookup_hit_oh[way] && lookup_hit_oh[other]) hit_unique = 1'b0;
      end
    end
  end

  // 上一拍的清除脉冲必须在这一拍把全部有效位清掉。
  logic invalidate_apply_q;
  logic any_valid;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) invalidate_apply_q <= 1'b0;
    else invalidate_apply_q <= invalidate_apply_i;
  end
  always_comb begin
    any_valid = 1'b0;
    for (int unsigned way = 0; way < WayCount; way++) begin
      for (int unsigned set = 0; set < SetCount; set++) begin
        if (valid_q[way][set]) any_valid = 1'b1;
      end
    end
  end
`endif

  `CHECK(ICacheArrayHitUnique, hit_unique)
  `CHECK(ICacheArrayInvalidateClearsValid, !invalidate_apply_q || !any_valid)

endmodule
