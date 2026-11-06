// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 条件分支与 JAL 共用表项；保存 valid、截断 PC 标签、目标低位和 JAL 标志。
// 组合查询、同步写入，无写入旁路；RR 只在插入新项时推进。
module branch_target_table
  import riscv_core_pkg::*;
#(
  parameter int unsigned SetCount = BtbSetCount,
  parameter int unsigned WayCount = BtbWayCount
)(
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,
  input btb_tag_t predict_tag_i,
  output logic predict_hit_o,
  output btb_target_t predict_target_o,
  output logic predict_is_jal_o,
  input logic update_valid_i,
  input btb_tag_t update_tag_i,
  input btb_target_t update_target_i,
  input logic update_is_jal_i
);

  localparam int unsigned SetIndexWidth = (SetCount > 1) ? $clog2(SetCount) : 1;
  localparam int unsigned WayIndexWidth = (WayCount > 1) ? $clog2(WayCount) : 1;
  typedef logic [SetIndexWidth-1:0] set_index_t;
  typedef logic [WayIndexWidth-1:0] way_index_t;
  typedef struct packed {
    logic valid;
    btb_tag_t tag;
    btb_target_t target;
    logic is_jal;
  } entry_t;

  entry_t entries_q [SetCount][WayCount];
  set_index_t predict_set, update_set;
  way_index_t replacement_way, update_way;
  logic update_hit;

  initial begin
    if (SetCount == 0 || ((SetCount & (SetCount - 1)) != 0))
      $fatal(1, "BTB SetCount must be a positive power of two");
    if (WayCount == 0 || ((WayCount & (WayCount - 1)) != 0))
      $fatal(1, "BTB WayCount must be a positive power of two");
    if (BtbPcWidth < 1 || BtbPcWidth > XLen - 2 || BtbPcWidth < $clog2(SetCount))
      $fatal(1, "BTB tag must cover set index and fit PC[31:2]");
    if (BtbTargetWidth < 2 || BtbTargetWidth > XLen)
      $fatal(1, "BTB target width must be in [2, 32]");
  end

  assign predict_set = set_index_t'(predict_tag_i & btb_tag_t'(SetCount - 1));
  assign update_set = set_index_t'(update_tag_i & btb_tag_t'(SetCount - 1));

  // 每组标签唯一；按命中掩码 OR 选择目标，避免优先级多路器链。
  always_comb begin
    predict_hit_o = 1'b0;
    predict_target_o = '0;
    predict_is_jal_o = 1'b0;
    for (int unsigned way = 0; way < WayCount; way++) begin
      if (!invalidate_i && entries_q[predict_set][way].valid &&
          entries_q[predict_set][way].tag == predict_tag_i) begin
        predict_hit_o = 1'b1;
        predict_target_o |= entries_q[predict_set][way].target;
        predict_is_jal_o |= entries_q[predict_set][way].is_jal;
      end
    end
  end

  // 写入位置：命中项、编号最小的空路、RR 指针，依次优先。
  always_comb begin
    logic empty_found;

    update_way = replacement_way;
    update_hit = 1'b0;
    empty_found = 1'b0;
    for (int unsigned way = 0; way < WayCount; way++) begin
      if (!update_hit && entries_q[update_set][way].valid &&
          entries_q[update_set][way].tag == update_tag_i) begin
        update_way = way_index_t'(way);
        update_hit = 1'b1;
      end else if (!update_hit && !empty_found && !entries_q[update_set][way].valid) begin
        // 先记住首个空路；后续命中仍覆盖它，复用已有表项。
        update_way = way_index_t'(way);
        empty_found = 1'b1;
      end
    end
  end

  // 单路表不需要替换状态，也不产生零宽索引。
  if (WayCount > 1) begin : gen_rr
    way_index_t next_way_q [SetCount];
    assign replacement_way = next_way_q[update_set];
    always_ff @(posedge clk_i) begin
      if (!rst_ni || invalidate_i) begin
        for (int unsigned set_idx = 0; set_idx < SetCount; set_idx++)
          next_way_q[set_idx] <= '0;
      end else if (update_valid_i && !update_hit) begin
        next_way_q[update_set] <= update_way + 1'b1;
      end
    end
  end else begin : gen_single_way
    assign replacement_way = '0;
  end

  // 只复位 valid；标签和目标由 valid 屏蔽。失效优先于同拍训练。
  always_ff @(posedge clk_i) begin
    if (!rst_ni || invalidate_i) begin
      for (int unsigned set_idx = 0; set_idx < SetCount; set_idx++)
        for (int unsigned way = 0; way < WayCount; way++)
          entries_q[set_idx][way].valid <= 1'b0;
    end else if (update_valid_i) begin
      entries_q[update_set][update_way] <= '{
        valid: 1'b1, tag: update_tag_i, target: update_target_i, is_jal: update_is_jal_i
      };
    end
  end
endmodule
