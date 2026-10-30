// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// BRANCH/JAL/RET 三表 + Bimodal + RAS；组合查询、EX 同步训练，无查询副作用。
module branch_predictor
  import riscv_core_pkg::*;
#(
  parameter bit Enable = BtbEnable,
  parameter int unsigned BranchEntries = BranchBtbEntries,
  parameter int unsigned JalEntries = JalBtbEntries,
  parameter int unsigned RetEntries = RetBtbEntries,
  parameter int unsigned RasEntries = RasEntryCount,
  parameter int unsigned BhtEntries = BhtEntryCount
)(
  input logic clk_i,
  input logic rst_ni,
  // FENCE.I 当拍屏蔽预测，上升沿清除有效状态；失效优先于训练。
  input logic invalidate_i,
  branch_predict_if.responder predict,
  branch_update_if.consumer update
);

  initial begin
    if (BhtEntries < 2 || ((BhtEntries & (BhtEntries - 1)) != 0))
      $fatal(1, "BHT entries must be a power of two, at least two");
    if (BtbPcWidth < $clog2(BhtEntries) || BtbPcWidth > XLen - 2)
      $fatal(1, "BTB tag must cover BHT index and fit PC[31:2]");
    if (BtbTargetWidth < 3 || BtbTargetWidth > XLen)
      $fatal(1, "BTB/RAS target width must be in [3, 32]");
    if (RasEntries < 2 || ((RasEntries & (RasEntries - 1)) != 0))
      $fatal(1, "RAS entries must be a power of two, at least two");
  end

  if (Enable) begin : gen_predictor
    typedef logic [$clog2(BhtEntries)-1:0] bht_index_t;
    typedef logic [$clog2(RasEntries)-1:0] ras_index_t;
    typedef logic [$clog2(RasEntries+1)-1:0] ras_count_t;

    logic branch_hit, jal_hit, ret_hit;
    btb_target_t branch_target;
    logic [BtbTargetWidth-1:2] jal_target;
    logic [1:0] counters_q [BhtEntries];
    bht_index_t predict_index, update_index;
    ras_link_t ras_links_q [RasEntries];
    ras_index_t ras_next_q, ras_next_d, ras_write_index, ras_top_index;
    ras_count_t ras_count_q, ras_count_d;
    logic select_branch, select_jal, select_ret;

    assign predict_index = bht_index_t'(predict.tag);
    assign update_index = bht_index_t'(update.payload.tag);

    branch_target_table #(.Entries(BranchEntries)) u_branch_table (
      .clk_i, .rst_ni, .invalidate_i,
      .predict_tag_i(predict.tag), .hit_o(branch_hit), .data_o(branch_target),
      .update_valid_i(update.valid && update.payload.kind == BTB_BRANCH),
      .update_tag_i(update.payload.tag), .update_data_i(update.payload.target)
    );

    // JAL 与 RET 独立训练，没有类型位，也不互相挤占条目。
    branch_target_table #(.Entries(JalEntries), .DataWidth(BtbTargetWidth-2)) u_jal_table (
      .clk_i, .rst_ni, .invalidate_i,
      .predict_tag_i(predict.tag), .hit_o(jal_hit), .data_o(jal_target),
      .update_valid_i(update.valid && update.payload.kind == BTB_JAL),
      .update_tag_i(update.payload.tag),
      .update_data_i(update.payload.target[BtbTargetWidth-1:2])
    );

    branch_target_table #(.Entries(RetEntries), .DataWidth(0)) u_ret_table (
      .clk_i, .rst_ni, .invalidate_i,
      .predict_tag_i(predict.tag), .hit_o(ret_hit), .data_o(),
      .update_valid_i(update.valid && update.payload.kind == BTB_RET),
      .update_tag_i(update.payload.tag), .update_data_i(1'b0)
    );

    // RET > JAL > BRANCH；RET 命中但空栈时顺序取指，不回退其他表。
    assign select_branch = !ret_hit && !jal_hit && branch_hit && counters_q[predict_index][1];
    assign select_jal = !ret_hit && jal_hit;
    assign select_ret = ret_hit && (ras_count_q != '0);
    assign ras_top_index = ras_next_q - ras_index_t'(1);
    // 三个互斥来源并行掩码归并，避免目标经过两层优先级选择器。
    assign predict.payload = '{
      taken: select_branch || select_jal || select_ret,
      target: ({$bits(btb_target_t){select_branch}} & branch_target) |
              ({$bits(btb_target_t){select_jal}} & {jal_target, 1'b0}) |
              ({$bits(btb_target_t){select_ret}} & {ras_links_q[ras_top_index], 1'b0})
    };

    // 仅条件分支更新方向计数器；BTB 缺失也训练，01 弱不跳转冷启动。
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

    // 环形栈：满时覆盖最老项，空 pop 保持空；pop+push 先弹后压。
    // 指针指向下一写入位置，二次幂容量自然回绕，无需搬移地址寄存器。
    always_comb begin
      ras_next_d = ras_next_q;
      ras_count_d = ras_count_q;
      if (update.payload.ras_pop && ras_count_q != '0) begin
        ras_next_d = ras_next_q - ras_index_t'(1);
        ras_count_d = ras_count_q - ras_count_t'(1);
      end
      ras_write_index = ras_next_d;
      if (update.payload.ras_push) begin
        ras_next_d = ras_next_d + ras_index_t'(1);
        if (ras_count_d < ras_count_t'(RasEntries)) ras_count_d = ras_count_d + ras_count_t'(1);
      end
    end

    // 只复位指针与有效项计数；查询不修改栈，EX 改道无需恢复检查点。
    always_ff @(posedge clk_i) begin
      if (!rst_ni || invalidate_i) begin
        ras_next_q <= '0;
        ras_count_q <= '0;
      end
      else if (update.valid) begin
        ras_next_q <= ras_next_d;
        ras_count_q <= ras_count_d;
      end
      if (update.valid && update.payload.ras_push && rst_ni && !invalidate_i)
        ras_links_q[ras_write_index] <= update.payload.link;
    end
  end else begin : gen_disabled
    logic unused_inputs;
    assign unused_inputs = ^{clk_i, rst_ni, invalidate_i, predict.tag, update.valid, update.payload};
    assign predict.payload = '0;
  end
endmodule
