// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 截断标签/目标的 RR BTB + Bimodal；组合查询、同步训练，无写入旁路。
// EX 负责筛选训练事件，并核对取指时的预测方向与目标。
module branch_predictor
  import riscv_core_pkg::*;
#(
  parameter bit Enable = BtbEnable,
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

  initial begin
    if (SetCount == 0 || ((SetCount & (SetCount - 1)) != 0))
      $fatal(1, "BTB SetCount must be a positive power of two");
    if (WayCount < 2 || ((WayCount & (WayCount - 1)) != 0))
      $fatal(1, "BTB WayCount must be a power of two, at least two");
    if (BhtEntries < 2 || ((BhtEntries & (BhtEntries - 1)) != 0))
      $fatal(1, "BHT entries must be a power of two, at least two");
    if (BtbPcWidth < 1 || BtbPcWidth > XLen - 2 ||
        BtbPcWidth < $clog2(SetCount) || BtbPcWidth < $clog2(BhtEntries))
      $fatal(1, "BTB tag must cover set/BHT indices and fit PC[31:2]");
    if (BtbTargetWidth < 2 || BtbTargetWidth > XLen)
      $fatal(1, "BTB target width must be in [2, 32]");
  end

  if (Enable && SetCount > 0 && WayCount >= 2 && BhtEntries >= 2) begin : gen_table
    localparam int unsigned SetIndexWidth = (SetCount > 1) ? $clog2(SetCount) : 1;
    localparam int unsigned WayIndexWidth = $clog2(WayCount);
    localparam int unsigned BhtIndexWidth = $clog2(BhtEntries);
    typedef logic [SetIndexWidth-1:0] set_index_t;
    typedef logic [WayIndexWidth-1:0] way_index_t;
    typedef logic [BhtIndexWidth-1:0] bht_index_t;
    typedef struct packed {
      logic valid;
      btb_tag_t tag;
      btb_target_t target;
      btb_entry_type_e kind;
    } entry_t;

    entry_t entries_q [SetCount][WayCount];
    way_index_t next_way_q [SetCount];
    logic [1:0] counters_q [BhtEntries];
    set_index_t predict_set, update_set;
    bht_index_t predict_index, update_index;
    way_index_t update_way;
    logic update_hit, way_found;

    assign predict_set = set_index_t'(predict.tag & btb_tag_t'(SetCount - 1));
    assign update_set = set_index_t'(update.payload.tag & btb_tag_t'(SetCount - 1));
    assign predict_index = bht_index_t'(predict.tag);
    assign update_index = bht_index_t'(update.payload.tag);

    // 每组标签唯一，用命中掩码做 OR 选择，避免目标数据的优先级多路器链。
    always_comb begin
      predict.payload = '0;
      for (int unsigned way = 0; way < WayCount; way++) begin
        if (!invalidate_i && entries_q[predict_set][way].valid &&
            entries_q[predict_set][way].tag == predict.tag &&
            ((entries_q[predict_set][way].kind == BTB_JAL) || counters_q[predict_index][1])) begin
          predict.payload.taken = 1'b1;
          predict.payload.target |= entries_q[predict_set][way].target;
        end
      end
    end

    // 写入位置：先复用命中项，再找第一个空路，满组时按轮转指针替换。
    always_comb begin
      update_way = next_way_q[update_set];
      update_hit = 1'b0;
      for (int unsigned way = 0; way < WayCount; way++) begin
        if (!update_hit && entries_q[update_set][way].valid &&
            entries_q[update_set][way].tag == update.payload.tag) begin
          update_way = way_index_t'(way);
          update_hit = 1'b1;
        end
      end
      way_found = update_hit;
      for (int unsigned way = 0; way < WayCount; way++) begin
        if (!way_found && !entries_q[update_set][way].valid) begin
          update_way = way_index_t'(way);
          way_found = 1'b1;
        end
      end
    end

    // 仅 valid 和 RR 指针需要复位；标签、目标、类型由 valid 屏蔽。
    always_ff @(posedge clk_i) begin
      if (!rst_ni || invalidate_i) begin
        for (int unsigned set_idx = 0; set_idx < SetCount; set_idx++) begin
          next_way_q[set_idx] <= '0;
          for (int unsigned way = 0; way < WayCount; way++)
            entries_q[set_idx][way].valid <= 1'b0;
        end
      end else if (update.valid) begin
        entries_q[update_set][update_way] <= '{
          valid: 1'b1, tag: update.payload.tag,
          target: update.payload.target, kind: update.payload.kind
        };
        // 二次幂路数自然回绕；命中训练不改变替换顺序。
        if (!update_hit) next_way_q[update_set] <= update_way + 1'b1;
      end
    end

    // BHT 与 BTB 独立训练：即使 BTB 未命中，条件分支也更新对应计数器。
    // 01 弱不跳转冷启动；JAL 不污染方向历史。
    always_ff @(posedge clk_i) begin
      if (!rst_ni || invalidate_i) begin
        for (int unsigned idx = 0; idx < BhtEntries; idx++) counters_q[idx] <= 2'b01;
      end else if (update.valid && update.payload.kind == BTB_BRANCH) begin
        if (update.payload.taken && counters_q[update_index] != 2'b11)  
          counters_q[update_index] <= counters_q[update_index] + 2'b01;
        else if (!update.payload.taken && counters_q[update_index] != 2'b00)
          counters_q[update_index] <= counters_q[update_index] - 2'b01;
      end
    end
  end else begin : gen_disabled
    logic unused_inputs;
    assign unused_inputs = ^{clk_i, rst_ni, invalidate_i, predict.tag, update.valid,
                             update.payload};
    assign predict.payload = '0;
  end
endmodule
