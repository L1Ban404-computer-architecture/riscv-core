// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 控制流执行：判定方向和目标，核对预测快照，生成改道和训练事件。
// 方向/目标是持续组合结果；事件只在握手且最终无异常时有效。
module branch_unit
  import riscv_core_pkg::*;
(
  input branch_op_e branch_op_i,
  input pc_t direct_target_i,
  input word_t alu_target_i,
  input word_t rs1_value_i,
  input word_t rs2_value_i,
  input word_t imm_i,
  input pc_t pc_plus4_i,
  input execution_prediction_payload_t prediction_i,
  input logic fence_i,
  input logic fire_i,
  input logic upstream_exception_valid_i,
  input logic exception_valid_i,

  output logic taken_o,
  output pc_t target_pc_o,
  redirect_if.producer redirect,
  branch_update_if.producer branch_update
);

  word_t required_carry, generated_carry;
  logic jalr_target_match, target_match;

  always_comb begin
    taken_o = 1'b0;
    case (branch_op_i)
      BR_JAL, BR_JALR: taken_o = 1'b1;
      BR_BEQ: taken_o = rs1_value_i == rs2_value_i;
      BR_BNE: taken_o = rs1_value_i != rs2_value_i;
      BR_BLT: taken_o = $signed(rs1_value_i) < $signed(rs2_value_i);
      BR_BGE: taken_o = $signed(rs1_value_i) >= $signed(rs2_value_i);
      BR_BLTU: taken_o = rs1_value_i < rs2_value_i;
      BR_BGEU: taken_o = rs1_value_i >= rs2_value_i;
      default: ;
    endcase
  end

  // JALR 清除最低位后，EX 仍须检查 IALIGN=32 的两位对齐要求。
  assign target_pc_o = (branch_op_i == BR_JALR) ? (alu_target_i & word_t'(~1)) : direct_target_i;

  // 若 rs1+imm 等于预测目标，则每位所需的输入进位为 rs1^imm^target。
  // 并行校验这些进位能否由低一位产生，无需先等待完整加法结果。
  // JALR 忽略和的 bit 0，因此从实际的低位进位 rs1[0]&imm[0] 开始检查。
  assign required_carry = rs1_value_i ^ imm_i ^ prediction_i.target_pc;
  assign generated_carry = (rs1_value_i & imm_i) |
      ((rs1_value_i | imm_i) & required_carry);
  assign jalr_target_match = (required_carry[1] == (rs1_value_i[0] & imm_i[0])) &&
      (required_carry[XLen-1:2] == generated_carry[XLen-2:1]);
  assign target_match = (branch_op_i == BR_JALR) ? jalr_target_match :
      (prediction_i.target_pc == direct_target_i);

  // FENCE.I 的改道与失效留到 WB；其余指令用实际方向、完整目标纠正预测。
  assign redirect.valid = fire_i && !exception_valid_i && !fence_i &&
      ((prediction_i.taken != taken_o) ||
       (taken_o && !target_match));
  assign redirect.payload = '{
    target_pc: taken_o ? target_pc_o : pc_plus4_i,
    imem_invalidate: 1'b0
  };

  // 只训练合法 B/J；未跳转的非对齐目标不会产生异常，仍可训练。
  // B/J 不访问数据存储器，训练无需经过 JALR 加法或访存异常归并路径。
  assign branch_update.valid = fire_i && !upstream_exception_valid_i &&
      !(taken_o && (direct_target_i[1:0] != 2'b00)) &&
      (branch_op_i inside {BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU, BR_JAL});
  assign branch_update.payload = '{
    // 仅在标签宽度内恢复原 PC 索引，不引入完整 PC 数据通路。
    tag: btb_tag_t'(pc_plus4_i >> 2) - btb_tag_t'(1),
    target: direct_target_i[BtbTargetWidth-1:1],
    kind: (branch_op_i == BR_JAL) ? BTB_JAL : BTB_BRANCH,
    taken: taken_o
  };

endmodule
