// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

module branch_predictor_test_top
  import riscv_core_pkg::*;
#(
  parameter int unsigned SetCount = 1,
  parameter int unsigned WayCount = 4,
  parameter int unsigned BhtEntries = 16
)(
  input logic clk_i, rst_ni, invalidate_i,
  input pc_t pc_i,
  input logic update_valid_i,
  input pc_t update_pc_i, update_target_i,
  input logic update_jal_i, update_taken_i,
  output logic taken_o,
  output pc_t target_o,
  output logic disabled_taken_o,
  output pc_t disabled_target_o
);
  branch_predict_if predict ();
  branch_predict_if disabled ();
  branch_update_if update ();
  assign predict.tag = btb_tag_t'(pc_i >> 2);
  assign disabled.tag = btb_tag_t'(pc_i >> 2);
  assign taken_o = predict.payload.taken;
  assign target_o = predict.payload.taken ? btb_target_pc(pc_i, predict.payload.target) : '0;
  assign disabled_taken_o = disabled.payload.taken;
  assign disabled_target_o = disabled.payload.taken ?
      btb_target_pc(pc_i, disabled.payload.target) : '0;
  assign update.valid = update_valid_i;
  assign update.payload = '{tag: btb_tag_t'(update_pc_i >> 2),
      target: update_target_i[BtbTargetWidth-1:1],
      kind: update_jal_i ? BTB_JAL : BTB_BRANCH, taken: update_taken_i};
  branch_predictor #(.SetCount(SetCount), .WayCount(WayCount), .BhtEntries(BhtEntries)) dut (
    .clk_i, .rst_ni, .invalidate_i, .predict, .update
  );
  branch_predictor #(.Enable(1'b0)) disabled_dut (
    .clk_i, .rst_ni, .invalidate_i, .predict(disabled), .update
  );
endmodule
