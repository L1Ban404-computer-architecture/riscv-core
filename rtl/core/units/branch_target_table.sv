// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 小容量全相联 RR 表。DataWidth=0 时只有标签，用于识别 RET，不分配目标寄存器。
module branch_target_table
  import riscv_core_pkg::*;
#(
  parameter int unsigned Entries = 4,
  parameter int unsigned DataWidth = $bits(btb_target_t)
)(
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,
  input btb_tag_t predict_tag_i,
  output logic hit_o,
  output logic [(DataWidth > 0 ? DataWidth : 1)-1:0] data_o,
  input logic update_valid_i,
  input btb_tag_t update_tag_i,
  input logic [(DataWidth > 0 ? DataWidth : 1)-1:0] update_data_i
);

  localparam int unsigned WayWidth = $clog2(Entries);
  typedef logic [WayWidth-1:0] way_t;
  typedef struct packed {
    logic valid;
    btb_tag_t tag;
  } entry_t;

  entry_t entries_q [Entries];
  way_t next_way_q, update_way;
  logic update_hit, found;
  logic [Entries-1:0] predict_hits;

  initial begin
    if (Entries < 2 || ((Entries & (Entries - 1)) != 0))
      $fatal(1, "BTB entries must be a power of two, at least two");
  end

  // 失效当拍屏蔽查询；标签匹配同时用于目标选择。
  always_comb begin
    for (int unsigned way = 0; way < Entries; way++)
      predict_hits[way] = !invalidate_i && entries_q[way].valid && entries_q[way].tag == predict_tag_i;
  end
  assign hit_o = |predict_hits;

  if (DataWidth > 0) begin : gen_data
    logic [DataWidth-1:0] data_q [Entries];
    always_comb begin
      data_o = '0;
      for (int unsigned way = 0; way < Entries; way++)
        if (predict_hits[way]) data_o |= data_q[way];
    end
    // 数据无需复位，有效位负责屏蔽；与标签在同一次训练事件中更新。
    always_ff @(posedge clk_i) begin
      if (rst_ni && !invalidate_i && update_valid_i) data_q[update_way] <= update_data_i;
    end
  end else begin : gen_tag_only
    logic unused_data;
    assign unused_data = ^update_data_i;
    assign data_o = '0;
  end

  // 先复用命中项，再找空项，满表才按 RR 替换。
  always_comb begin
    update_way = next_way_q;
    update_hit = 1'b0;
    for (int unsigned way = 0; way < Entries; way++) begin
      if (!update_hit && entries_q[way].valid && entries_q[way].tag == update_tag_i) begin
        update_way = way_t'(way);
        update_hit = 1'b1;
      end
    end
    found = update_hit;
    for (int unsigned way = 0; way < Entries; way++) begin
      if (!found && !entries_q[way].valid) begin
        update_way = way_t'(way);
        found = 1'b1;
      end
    end
  end

  // 只复位有效位与 RR 指针；命中训练不改变替换顺序。
  always_ff @(posedge clk_i) begin
    if (!rst_ni || invalidate_i) begin
      next_way_q <= '0;
      for (int unsigned way = 0; way < Entries; way++) entries_q[way].valid <= 1'b0;
    end else if (update_valid_i) begin
      entries_q[update_way] <= '{valid: 1'b1, tag: update_tag_i};
      if (!update_hit) next_way_q <= update_way + way_t'(1);
    end
  end
endmodule
