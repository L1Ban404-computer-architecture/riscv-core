// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 组合查询 tag/data，lookup 保存查询快照。回填时逐字写入，无错误末拍置 valid。
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

  typedef logic [SetIndexW-1:0] set_index_t;
  typedef logic [WordIndexW-1:0] word_index_t;
  typedef logic [WayIndexW-1:0] way_index_t;
  typedef logic [TagW-1:0] tag_t;
  typedef logic [DataAddrW-1:0] data_addr_t;
  typedef lookup.payload_t lookup_payload_t;

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
  logic lookup_stream_ready;
  logic lookup_push;
  logic refill_line_conflict;

  set_index_t refill_set;
  tag_t refill_tag;
  word_index_t refill_addr_word;
  logic [WayCount-1:0] refill_select_valid;
  way_index_t refill_victim_combo;
  way_index_t refill_way_q;
  logic refill_way_locked_q;
  logic refill_start;
  logic refill_done;

  // 地址布局为 {tag, set, line offset}，data 阵列按 {set, word} 线性编址。
  function automatic set_index_t set_from_addr(input logic [AddrWidth-1:0] address);
    return (SetCount == 1) ? '0 : set_index_t'(address >> BlockOffsetW);
  endfunction

  function automatic word_index_t word_from_addr(input logic [AddrWidth-1:0] address);
    return (WordCount == 1) ? '0 : word_index_t'(address >> $clog2(DataWidth / 8));
  endfunction

  function automatic tag_t tag_from_addr(input logic [AddrWidth-1:0] address);
    return tag_t'(address >> (BlockOffsetW + SetIndexBits));
  endfunction

  function automatic data_addr_t data_addr_from(input set_index_t set, input word_index_t word);
    return data_addr_t'(set) * DataAddrW'(WordCount) + data_addr_t'(word);
  endfunction

  // 查询：比较各路 tag，将命中结果和数据一起锁存。
  assign lookup_set = set_from_addr(core_bus.req_payload.addr);
  assign lookup_tag = tag_from_addr(core_bus.req_payload.addr);
  assign lookup_word = word_from_addr(core_bus.req_payload.addr);

  always_comb begin
    lookup_rdata = '0;
    for (int unsigned way = 0; way < WayCount; way++) begin
      lookup_hit_oh[way] = core_bus.req_valid && valid_q[way][lookup_set] &&
          (tag_rdata[way] == lookup_tag);
      lookup_rdata |= {DataWidth{lookup_hit_oh[way]}} & data_rdata[way];
    end
  end

  assign lookup_hit = |lookup_hit_oh;
  assign lookup_push_payload = '{addr: core_bus.req_payload.addr,
      rdata: lookup_rdata, hit: lookup_hit};
  // 回填目标 line 完成前禁止查询；分配当拍仍能读取牺牲路的旧内容。
  assign refill_line_conflict = refill.valid &&
      ((core_bus.req_payload.addr >> BlockOffsetW) == (refill.addr >> BlockOffsetW));
  assign core_bus.req_ready = lookup_stream_ready && !refill_line_conflict;
  assign lookup_push = core_bus.req_valid && core_bus.req_ready;

  stream_register #(
    .T(lookup_payload_t)
  ) u_lookup_stream (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .valid_i(core_bus.req_valid && !refill_line_conflict),
    .ready_o(lookup_stream_ready),
    .data_i(lookup_push_payload),
    .valid_o(lookup.valid),
    .ready_i(lookup.ready),
    .data_o(lookup.payload)
  );

  // 回填：起始时锁定牺牲路，所有 beat 都写入同一路。
  assign refill_set = set_from_addr(refill.addr);
  assign refill_tag = tag_from_addr(refill.addr);
  assign refill_addr_word = word_from_addr(refill.addr);
  assign refill_start = refill.valid && !refill_way_locked_q;
  assign refill_done = refill.beat_valid && refill.payload.last;

  always_comb begin
    for (int unsigned way = 0; way < WayCount; way++)
      refill_select_valid[way] = valid_q[way][refill_set];
  end

  // 查询握手更新命中历史，回填起始选择牺牲路。
  icache_replacement_policy #(
    .SetCount(SetCount),
    .WayCount(WayCount),
    .ReplacementPolicy(ReplacementPolicy)
  ) u_replacement_policy (
    .clk_i,
    .rst_ni,
    .select_set_i(refill_set),
    .select_valid_i(refill_select_valid),
    .select_en_i(refill_start),
    .victim_way_o(refill_victim_combo),
    .hit_valid_i(lookup_push && lookup_hit),
    .hit_set_i(lookup_set),
    .hit_oh_i(lookup_hit_oh)
  );

  // 每路的 tag/data 存储：查询组合读，回填写入。
  for (genvar way = 0; way < WayCount; way++) begin : gen_way_mem
    logic tag_we;
    logic data_we;

    assign tag_we = refill_start && (refill_victim_combo == way_index_t'(way));
    assign data_we = refill.beat_valid && (refill_way_q == way_index_t'(way));

    mem_1r1w #(
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

    mem_1r1w #(
      .Width(DataWidth),
      .Depth(DataDepth),
      .CombRead(1'b1)
    ) u_data (
      .clk_i,
      .ren_i(1'b1),
      .raddr_i(data_addr_from(lookup_set, lookup_word)),
      .rdata_o(data_rdata[way]),
      .wen_i(data_we),
      .waddr_i(data_addr_from(refill_set, refill_addr_word)),
      .wdata_i(refill.payload.data)
    );
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      refill_way_locked_q <= 1'b0;
      refill_way_q <= '0;
    end else if (refill_start) begin
      refill_way_q <= refill_victim_combo;
      refill_way_locked_q <= 1'b1;
    end else if (refill_done) begin
      refill_way_locked_q <= 1'b0;
    end
  end

  // 分配时清 valid，只有完整且无错误的回填才重新置位。
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int unsigned way = 0; way < WayCount; way++)
        for (int unsigned set = 0; set < SetCount; set++) valid_q[way][set] <= 1'b0;
    end else if (invalidate_apply_i) begin
      for (int unsigned way = 0; way < WayCount; way++)
        for (int unsigned set = 0; set < SetCount; set++) valid_q[way][set] <= 1'b0;
    end else if (refill_start) begin
      valid_q[refill_victim_combo][refill_set] <= 1'b0;
    end else if (refill_done && !refill.payload.error) begin
      valid_q[refill_way_q][refill_set] <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  ICacheArrayBeatAfterAllocation: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !refill.beat_valid || (refill.valid && refill_way_locked_q)));
  ICacheArrayHitUnique: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      (lookup_hit_oh & (lookup_hit_oh - WayCount'(1))) == '0));
`endif

endmodule
