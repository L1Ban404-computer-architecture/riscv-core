// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 两种静态方向算法均无训练状态，只判断条件分支。
module branch_predictor_bht
  import riscv_core_pkg::*;
#(
  parameter bht_algorithm_e Algorithm = BhtAlgorithm
)(
  input pc_t predict_pc_i,
  input pc_t predict_target_i,
  output logic predict_taken_o
);
  if (Algorithm == BHT_BTFN) begin : gen_btfn
    // 先截为 RV32 差值，再解释符号；跨地址空间边界及零偏移同样适用。
    pc_t offset;
    assign offset = predict_target_i - predict_pc_i;
    assign predict_taken_o = $signed(offset) < 0;
  end else begin : gen_not_taken
    logic unused_inputs;
    assign unused_inputs = ^{predict_pc_i, predict_target_i};
    assign predict_taken_o = 1'b0;
  end

  initial begin
    if (!(Algorithm inside {BHT_BTFN, BHT_NOT_TAKEN}))
      $fatal(1, "unsupported BHT algorithm");
  end
endmodule
