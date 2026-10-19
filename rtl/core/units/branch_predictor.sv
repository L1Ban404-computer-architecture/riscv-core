// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// BTFN：条件分支按 EX 提供的立即数方向预测，JAL 始终预测跳转。
// BTB 使用完整 PC 标签，组合查询、同步训练；查询不更新替换状态，无写入旁路。
// 省略后级目标比较的前提：代码/映射改变须失效，且失效后不得写回旧代码的训练。
module branch_predictor
  import riscv_core_pkg::*;
#(
  parameter bit Enable = BtbEnable,
  parameter int unsigned SetCount = BtbSetCount,
  parameter int unsigned WayCount = BtbWayCount
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
    if (WayCount == 0) $fatal(1, "BTB WayCount must be positive");
  end

  // 零容量由参数检查报错，不展开数组。
  if (Enable && SetCount > 0 && WayCount > 0) begin : gen_table
    localparam int unsigned SetIndexWidth = (SetCount > 1) ? $clog2(SetCount) : 1;
    localparam int unsigned WayIndexWidth = (WayCount > 1) ? $clog2(WayCount) : 1;
    typedef logic [SetIndexWidth-1:0] set_index_t;
    typedef logic [WayIndexWidth-1:0] way_index_t;
    typedef struct packed {
      logic valid;
      pc_t pc;
      pc_t target_pc;
      btb_entry_type_e kind;
      logic backward;
    } entry_t;

    entry_t entries_q [SetCount][WayCount];
    entry_t update_entry;
    set_index_t predict_set, update_set;
    way_index_t next_way_q [SetCount];
    way_index_t update_way;
    logic update_enable, update_hit, way_found;

    assign predict_set = set_index_t'((predict.pc >> 2) & (SetCount - 1));
    assign update_set = set_index_t'((update.payload.pc >> 2) & (SetCount - 1));

    // 查询：命中后，JAL 或后向条件分支预测跳转，其余返回顺序执行。
    always_comb begin
      predict.taken = 1'b0;
      predict.target_pc = '0;
      for (int unsigned way = 0; way < WayCount; way++) begin
        if (!invalidate_i && entries_q[predict_set][way].valid &&
            entries_q[predict_set][way].pc == predict.pc) begin
          predict.taken = (entries_q[predict_set][way].kind == BTB_JAL) ||
              entries_q[predict_set][way].backward;
          predict.target_pc = predict.taken ? entries_q[predict_set][way].target_pc : '0;
        end
      end
    end

    // 训练：只接受条件分支与 JAL，JALR、普通指令和未知操作不改变表项。
    always_comb begin
      update_entry = '{
        valid: 1'b1,
        pc: update.payload.pc,
        target_pc: update.payload.target_pc,
        kind: BTB_BRANCH,
        backward: update.payload.backward
      };
      update_enable = 1'b0;
      case (update.payload.branch_op)
        BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU:
          update_enable = update.valid && !invalidate_i;
        BR_JAL: begin
          update_enable = update.valid && !invalidate_i;
          update_entry.kind = BTB_JAL;
        end
        default: ;
      endcase
    end

    // 写入位置：先复用命中项，再找第一个空路，满组时按轮转指针替换。
    always_comb begin
      update_way = next_way_q[update_set];
      update_hit = 1'b0;
      for (int unsigned way = 0; way < WayCount; way++) begin
        if (!update_hit && entries_q[update_set][way].valid &&
            entries_q[update_set][way].pc == update.payload.pc) begin
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

    // 状态更新：失效只清 valid；训练写入表项，新分配时推进轮转指针。
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned set_idx = 0; set_idx < SetCount; set_idx++) begin
          next_way_q[set_idx] <= '0;
          for (int unsigned way = 0; way < WayCount; way++) entries_q[set_idx][way] <= '0;
        end
      end else if (invalidate_i) begin
        for (int unsigned set_idx = 0; set_idx < SetCount; set_idx++) begin
          for (int unsigned way = 0; way < WayCount; way++)
            entries_q[set_idx][way].valid <= 1'b0;
        end
      end else if (update_enable) begin
        entries_q[update_set][update_way] <= update_entry;
        if (!update_hit) begin
          // 显式回绕，支持单路和非二次幂路数；命中训练不改变替换顺序。
          next_way_q[update_set] <= (update_way == way_index_t'(WayCount - 1)) ?
              '0 : update_way + 1'b1;
        end
      end
    end
  end else begin : gen_disabled
    logic unused_inputs;
    assign unused_inputs = ^{clk_i, rst_ni, invalidate_i, predict.pc, update.valid,
                             update.payload};
    assign predict.taken = 1'b0;
    assign predict.target_pc = '0;
  end
endmodule
