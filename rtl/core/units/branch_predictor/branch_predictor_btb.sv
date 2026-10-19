// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 完整 PC 标签、组合读、同步训练。查询不改变替换状态，也没有写入旁路。
module branch_predictor_btb
  import riscv_core_pkg::*;
#(
  parameter bit Enable = BtbEnable,
  parameter int unsigned SetCount = BtbSetCount,
  parameter int unsigned WayCount = BtbWayCount,
  parameter btb_replacement_policy_e ReplacementPolicy = BtbReplacementPolicy
)(
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,
  input pc_t predict_pc_i,
  output logic predict_hit_o,
  output pc_t predict_target_o,
  output btb_entry_type_e predict_type_o,
  input logic update_valid_i,
  input pc_t update_pc_i,
  input pc_t update_target_i,
  input btb_entry_type_e update_type_i
);
  initial begin
    if (SetCount == 0 || ((SetCount & (SetCount - 1)) != 0))
      $fatal(1, "BTB SetCount must be a positive power of two");
    if (WayCount == 0) $fatal(1, "BTB WayCount must be positive");
    if (!(ReplacementPolicy inside {BTB_REPLACEMENT_ROUND_ROBIN, BTB_REPLACEMENT_LRU}))
      $fatal(1, "unsupported BTB replacement policy");
  end

  // 非法零容量不生成数组，由上方参数检查给出明确诊断。
  if (Enable && SetCount > 0 && WayCount > 0) begin : gen_table
    localparam int unsigned SetIndexWidth = (SetCount > 1) ? $clog2(SetCount) : 1;
    localparam int unsigned WayIndexWidth = (WayCount > 1) ? $clog2(WayCount) : 1;
    typedef logic [SetIndexWidth-1:0] set_index_t;
    typedef logic [WayIndexWidth-1:0] way_index_t;

    logic valid_q [SetCount][WayCount];
    pc_t pc_q [SetCount][WayCount];
    pc_t target_q [SetCount][WayCount];
    btb_entry_type_e type_q [SetCount][WayCount];
    set_index_t predict_set, update_set;
    way_index_t selected_way, victim_way;
    logic update_hit, selected;

    assign predict_set = set_index_t'((predict_pc_i >> 2) & (SetCount - 1));
    assign update_set = set_index_t'((update_pc_i >> 2) & (SetCount - 1));

    always_comb begin
      predict_hit_o = 1'b0;
      predict_target_o = '0;
      predict_type_o = BTB_BRANCH;
      for (int unsigned way = 0; way < WayCount; way++) begin
        if (!invalidate_i && valid_q[predict_set][way] && pc_q[predict_set][way] == predict_pc_i) begin
          predict_hit_o = 1'b1;
          predict_target_o = target_q[predict_set][way];
          predict_type_o = type_q[predict_set][way];
        end
      end
    end

    always_comb begin
      selected_way = victim_way;
      update_hit = 1'b0;
      for (int unsigned way = 0; way < WayCount; way++) begin
        if (!update_hit && valid_q[update_set][way] && pc_q[update_set][way] == update_pc_i) begin
          selected_way = way_index_t'(way);
          update_hit = 1'b1;
        end
      end
      selected = update_hit;
      for (int unsigned way = 0; way < WayCount; way++) begin
        if (!selected && !valid_q[update_set][way]) begin
          selected_way = way_index_t'(way);
          selected = 1'b1;
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned set_idx = 0; set_idx < SetCount; set_idx++) begin
          for (int unsigned way = 0; way < WayCount; way++) begin
            valid_q[set_idx][way] <= 1'b0;
            pc_q[set_idx][way] <= '0;
            target_q[set_idx][way] <= '0;
            type_q[set_idx][way] <= BTB_BRANCH;
          end
        end
      end else if (invalidate_i) begin
        // 只清 valid，避免为标签/目标/类型增加失效数据通路。
        for (int unsigned set_idx = 0; set_idx < SetCount; set_idx++) begin
          for (int unsigned way = 0; way < WayCount; way++) valid_q[set_idx][way] <= 1'b0;
        end
      end else if (update_valid_i) begin
        valid_q[update_set][selected_way] <= 1'b1;
        pc_q[update_set][selected_way] <= update_pc_i;
        target_q[update_set][selected_way] <= update_target_i;
        type_q[update_set][selected_way] <= update_type_i;
      end
    end

    if (ReplacementPolicy == BTB_REPLACEMENT_ROUND_ROBIN) begin : gen_rr
      way_index_t next_q [SetCount];
      assign victim_way = next_q[update_set];
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          for (int unsigned set_idx = 0; set_idx < SetCount; set_idx++) next_q[set_idx] <= '0;
        end else if (!invalidate_i && update_valid_i && !update_hit) begin
          // 显式回绕，支持单路及非二次幂路数。
          next_q[update_set] <= (selected_way == way_index_t'(WayCount - 1)) ?
              '0 : selected_way + 1'b1;
        end
      end
    end else begin : gen_lru
      // 0 为最新，最大有效名次为最旧；不使用随时间溢出的计数器。
      way_index_t rank_q [SetCount][WayCount];
      always_comb begin
        victim_way = '0;
        for (int unsigned way = 1; way < WayCount; way++) begin
          if (rank_q[update_set][way] > rank_q[update_set][victim_way])
            victim_way = way_index_t'(way);
        end
      end
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          for (int unsigned set_idx = 0; set_idx < SetCount; set_idx++) begin
            for (int unsigned way = 0; way < WayCount; way++) rank_q[set_idx][way] <= '0;
          end
        end else if (!invalidate_i && update_valid_i) begin
          for (int unsigned way = 0; way < WayCount; way++) begin
            if (way_index_t'(way) == selected_way) begin
              rank_q[update_set][way] <= '0;
            end else if (valid_q[update_set][way] &&
                (!update_hit || rank_q[update_set][way] < rank_q[update_set][selected_way])) begin
              rank_q[update_set][way] <= rank_q[update_set][way] + 1'b1;
            end
          end
        end
      end
    end
  end else begin : gen_disabled
    logic unused_inputs;
    assign unused_inputs = ^{clk_i, rst_ni, invalidate_i, predict_pc_i, update_valid_i,
                             update_pc_i, update_target_i, update_type_i};
    assign predict_hit_o = 1'b0;
    assign predict_target_o = '0;
    assign predict_type_o = BTB_BRANCH;
  end
endmodule
