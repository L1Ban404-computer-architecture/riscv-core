// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 组合读 tag/data，lookup 寄存命中结果和数据，背压时保持该次查询的快照。
// 回填开始时锁定牺牲路并清 valid，各 beat 按地址写入，无错误末拍才置 valid。
// 请求入口阻塞回填目标 line，其他 line 仍可查询。
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

  // 请求地址直通组合读口；命中结果推进 stream，背压时由寄存器保持。
  assign lookup_set = set_from_addr(core_bus.req_payload.addr);
  assign lookup_tag = tag_from_addr(core_bus.req_payload.addr);
  assign lookup_word = word_from_addr(core_bus.req_payload.addr);

  // 普通 tag/valid 比较；回填冲突只在请求入口处理。
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
  // 新 line 在回填结束前不能查询。分配当拍尚无回填数据写入，旧 line 命中
  // 可正常锁存；下一拍牺牲路有效位已清零，普通命中比较自然排除它。
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
    .data_o(lookup_stream_payload)
  );

  assign lookup.payload = lookup_stream_payload;

  // set/tag 在 WRAP 中保持不变，word offset 由 miss 的当前 beat 地址决定。
  assign refill_set = set_from_addr(refill.addr);
  assign refill_tag = tag_from_addr(refill.addr);
  assign refill_addr_word = word_from_addr(refill.addr);
  assign refill_start = refill.valid && !refill_way_locked_q;
  assign refill_done = refill.beat_valid && refill.payload.last;

  always_comb begin
    for (int unsigned way = 0; way < WayCount; way++)
      refill_select_valid[way] = valid_q[way][refill_set];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
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
    .select_en_i(refill_start),
    .victim_way_o(refill_victim_combo),
    .hit_valid_i(lookup_push && lookup_hit),
    .hit_set_i(lookup_set),
    .hit_oh_i(lookup_hit_oh)
  );

  // 分配时仅写 tag，数据 beat 至少在下一拍到达，因此写数据直接使用锁存路。
  // 组合读地址来自 CPU 请求，写地址来自 refill。
  for (genvar way = 0; way < WayCount; way++) begin : gen_way_mem
    logic tag_we;
    logic data_we;

    assign tag_we = refill_start && (refill_victim_combo == way_index_t'(way));
    assign data_we = refill.beat_valid && (refill_way_q == way_index_t'(way));

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
      .waddr_i(data_addr_from(refill_set, refill_addr_word)),
      .wdata_i(refill.payload.data)
    );
  end

  // 分配时清 valid，完整且无错误的末拍才置位。失效控制保证清除时没有回填。
  always_ff @(posedge clk_i or negedge rst_ni) begin
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
      for (int unsigned set = 0; set < SetCount; set++) any_valid |= valid_q[way][set];
    end
  end

  // 违反内部接口契约应直接暴露，不在数据通路中增加备用选路。
  ICacheArrayBeatAfterAllocation: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !refill.beat_valid || (refill.valid && refill_way_locked_q)));
  ICacheArrayInvalidateWhenIdle: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !invalidate_apply_i || !refill.valid));
  // x & (x - 1) 清除最低置位位，结果为零表示至多一路命中。
  ICacheArrayHitUnique: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      (lookup_hit_oh & (lookup_hit_oh - WayCount'(1))) == '0));
  ICacheArrayInvalidateClearsValid: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !invalidate_apply_q || !any_valid));
`endif

endmodule
