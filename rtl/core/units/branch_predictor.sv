// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 条件分支 BTB + Bimodal BHT，JAL 使用独立全相联 BTB。
// 只按 PC 组合查询，同步训练；EX 负责筛选合法训练事件和预测纠错。
module branch_predictor
  import riscv_core_pkg::*;
#(
  parameter int unsigned SetCount = BtbSetCount,
  parameter int unsigned WayCount = BtbWayCount,
  parameter int unsigned BhtEntries = BhtEntryCount,
  parameter int unsigned JalEntries = JalBtbEntryCount
)(
  input logic clk_i,
  input logic rst_ni,
  // FENCE.I 当拍屏蔽预测，上升沿失效；失效优先于训练。
  input logic invalidate_i,
  branch_predict_if.responder predict,
  branch_update_if.consumer update
);

  logic branch_hit, jal_hit, branch_taken, update_branch;
  btb_target_t branch_target, jal_target;

  assign update_branch = update.valid && !update.payload.is_jal;

  branch_target_table #(
    .SetCount(SetCount), .WayCount(WayCount)
  ) u_branch_btb (
    .clk_i, .rst_ni, .invalidate_i,
    .predict_tag_i(predict.tag),
    .predict_hit_o(branch_hit),
    .predict_target_o(branch_target),
    .update_valid_i(update_branch),
    .update_tag_i(update.payload.tag),
    .update_target_i(update.payload.target)
  );

  branch_target_table #(
    .SetCount(1), .WayCount(JalEntries)
  ) u_jal_btb (
    .clk_i, .rst_ni, .invalidate_i,
    .predict_tag_i(predict.tag),
    .predict_hit_o(jal_hit),
    .predict_target_o(jal_target),
    .update_valid_i(update.valid && update.payload.is_jal),
    .update_tag_i(update.payload.tag),
    .update_target_i(update.payload.target)
  );

  branch_bht #(.EntryCount(BhtEntries)) u_bht (
    .clk_i, .rst_ni, .invalidate_i,
    .predict_tag_i(predict.tag),
    .predict_taken_o(branch_taken),
    .update_valid_i(update_branch),
    .update_tag_i(update.payload.tag),
    .update_taken_i(update.payload.taken)
  );

  // 截断标签可能使两张表同时命中；与仿真模型一致，JAL 表优先。
  always_comb begin
    predict.payload = '0;
    if (jal_hit) predict.payload = '{taken: 1'b1, target: jal_target};
    else if (branch_hit && branch_taken)
      predict.payload = '{taken: 1'b1, target: branch_target};
  end
endmodule
