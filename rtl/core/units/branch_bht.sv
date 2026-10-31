// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// PC 索引的两位饱和计数器；只接受条件分支训练，不依赖 BTB 是否命中。
module branch_bht
  import riscv_core_pkg::*;
#(
  parameter int unsigned EntryCount = BhtEntryCount
)(
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,
  input btb_tag_t predict_tag_i,
  output logic predict_taken_o,
  input logic update_valid_i,
  input btb_tag_t update_tag_i,
  input logic update_taken_i
);

  localparam int unsigned IndexWidth = (EntryCount > 1) ? $clog2(EntryCount) : 1;
  typedef logic [IndexWidth-1:0] index_t;
  logic [1:0] counters_q [EntryCount];
  index_t predict_index, update_index;

  initial begin
    if (EntryCount < 2 || ((EntryCount & (EntryCount - 1)) != 0))
      $fatal(1, "BHT entries must be a power of two, at least two");
    if (BtbPcWidth < $clog2(EntryCount))
      $fatal(1, "BTB tag must cover BHT index");
  end

  assign predict_index = index_t'(predict_tag_i);
  assign update_index = index_t'(update_tag_i);
  assign predict_taken_o = counters_q[predict_index][1];

  // 01 弱不跳转冷启动；失效时一并重置方向历史。
  always_ff @(posedge clk_i) begin
    if (!rst_ni || invalidate_i) begin
      for (int unsigned idx = 0; idx < EntryCount; idx++) counters_q[idx] <= 2'b01;
    end else if (update_valid_i) begin
      if (update_taken_i && counters_q[update_index] != 2'b11)
        counters_q[update_index] <= counters_q[update_index] + 2'b01;
      else if (!update_taken_i && counters_q[update_index] != 2'b00)
        counters_q[update_index] <= counters_q[update_index] - 2'b01;
    end
  end
endmodule
