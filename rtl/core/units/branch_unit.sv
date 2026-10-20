// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 组合计算跳转条件和目标；EX 负责握手、异常检查及预测纠错。
module branch_unit
  import riscv_core_pkg::*;
(
  input branch_op_e branch_op_i,
  input word_t rs1_value_i,
  input word_t rs2_value_i,
  input word_t alu_target_i,

  output logic taken_o,
  output pc_t target_pc_o
);

  always_comb begin
    taken_o = 1'b0;
    case (branch_op_i)
      BR_JAL, BR_JALR: taken_o = 1'b1;
      BR_BEQ: taken_o = (rs1_value_i == rs2_value_i);
      BR_BNE: taken_o = (rs1_value_i != rs2_value_i);
      BR_BLT: taken_o = ($signed(rs1_value_i) < $signed(rs2_value_i));
      BR_BGE: taken_o = ($signed(rs1_value_i) >= $signed(rs2_value_i));
      BR_BLTU: taken_o = (rs1_value_i < rs2_value_i);
      BR_BGEU: taken_o = (rs1_value_i >= rs2_value_i);
      default: ;
    endcase
  end

  // JALR 清除最低位后，EX 仍须检查 IALIGN=32 的两位对齐要求。
  assign target_pc_o = (branch_op_i == BR_JALR) ? (alu_target_i & word_t'(~1)) : alu_target_i;

endmodule
