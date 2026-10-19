// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 仅 PC 查询；训练接受已确认合法的执行结果，不在此重复译码。
// 省略后级目标比较的前提：代码/映射改变须失效，且失效后不得写回旧代码的训练。
module branch_predictor
  import riscv_core_pkg::*;
#(
  parameter bht_algorithm_e Algorithm = BhtAlgorithm,
  parameter bit Enable = BtbEnable,
  parameter int unsigned SetCount = BtbSetCount,
  parameter int unsigned WayCount = BtbWayCount,
  parameter btb_replacement_policy_e ReplacementPolicy = BtbReplacementPolicy
)(
  input logic clk_i,
  input logic rst_ni,
  // FENCE.I 执行时置位；当拍屏蔽预测，上升沿失效，优先于训练。
  input logic invalidate_i,
  branch_predict_if.responder predict,
  branch_update_if.consumer update
);
  logic btb_update_valid, btb_hit, bht_taken;
  pc_t btb_target;
  btb_entry_type_e btb_update_type, btb_type;

  always_comb begin
    btb_update_valid = 1'b0;
    btb_update_type = BTB_BRANCH;
    case (update.payload.branch_op)
      BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU:
        btb_update_valid = update.valid;
      BR_JAL: begin
        btb_update_valid = update.valid;
        btb_update_type = BTB_JAL;
      end
      // JALR（包括 RET）、普通指令和未定义枚举均不更新或清除表项。
      default: ;
    endcase
  end

  branch_predictor_btb #(
    .Enable(Enable),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .ReplacementPolicy(ReplacementPolicy)
  ) u_btb (
    .clk_i,
    .rst_ni,
    .invalidate_i,
    .predict_pc_i(predict.pc),
    .predict_hit_o(btb_hit),
    .predict_target_o(btb_target),
    .predict_type_o(btb_type),
    .update_valid_i(btb_update_valid),
    .update_pc_i(update.payload.pc),
    .update_target_i(update.payload.target_pc),
    .update_type_i(btb_update_type)
  );

  branch_predictor_bht #(.Algorithm(Algorithm)) u_bht (
    .predict_pc_i(predict.pc),
    .predict_target_i(btb_target),
    .predict_taken_o(bht_taken)
  );

  assign predict.taken = btb_hit && ((btb_type == BTB_JAL) || bht_taken);
  assign predict.target_pc = predict.taken ? btb_target : '0;
endmodule
