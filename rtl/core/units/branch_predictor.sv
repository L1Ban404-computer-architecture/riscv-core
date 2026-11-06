// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 条件分支与 JAL 共用 RR BTB；条件分支方向使用 Bimodal BHT。
// 只按 PC 组合查询，同步训练；EX 负责筛选合法训练事件和预测纠错。
module branch_predictor
  import riscv_core_pkg::*;
#(
  parameter int unsigned SetCount = BtbSetCount,
  parameter int unsigned WayCount = BtbWayCount,
  parameter int unsigned BhtEntries = BhtEntryCount
)(
  input logic clk_i,
  input logic rst_ni,
  // FENCE.I 当拍屏蔽预测，上升沿失效；失效优先于训练。
  input logic invalidate_i,
  branch_predict_if.responder predict,
  branch_update_if.consumer update
);

  logic btb_hit, btb_is_jal, branch_taken, update_branch;
  btb_target_t btb_target;

  assign update_branch = update.valid && !update.payload.is_jal;

  branch_target_table #(
    .SetCount(SetCount), .WayCount(WayCount)
  ) u_btb (
    .clk_i, .rst_ni, .invalidate_i,
    .predict_tag_i(predict.tag),
    .predict_hit_o(btb_hit),
    .predict_target_o(btb_target),
    .predict_is_jal_o(btb_is_jal),
    .update_valid_i(update.valid),
    .update_tag_i(update.payload.tag),
    .update_target_i(update.payload.target),
    .update_is_jal_i(update.payload.is_jal)
  );

  branch_bht #(.EntryCount(BhtEntries)) u_bht (
    .clk_i, .rst_ni, .invalidate_i,
    .predict_tag_i(predict.tag),
    .predict_taken_o(branch_taken),
    .update_valid_i(update_branch),
    .update_tag_i(update.payload.tag),
    .update_taken_i(update.payload.taken)
  );

  // JAL 命中即跳转；条件分支命中后由 BHT 决定方向。
  always_comb begin
    predict.payload = '0;
    if (btb_hit && (btb_is_jal || branch_taken))
      predict.payload = '{taken: 1'b1, target: btb_target};
  end
endmodule
