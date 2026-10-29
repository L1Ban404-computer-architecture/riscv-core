// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 整数运算、比较与旁路统一输出结果；地址加法直接供访存和 JALR 使用。
module alu
  import riscv_core_pkg::*;
(
  input alu_op_e op_i,
  input word_t operand_a_i,
  input word_t operand_b_i,
  output word_t result_o,
  output word_t address_o
);

  // 地址不经过通用结果选择器，避免拉长对齐检查和跳转路径；ADD 复用此结果。
  assign address_o = operand_a_i + operand_b_i;

  always_comb begin
    case (op_i)
      ALU_ADD: result_o = address_o;
      ALU_SUB: result_o = operand_a_i - operand_b_i;
      ALU_SLL: result_o = operand_a_i << operand_b_i[4:0];
      ALU_SLT: result_o = word_t'($signed(operand_a_i) < $signed(operand_b_i));
      ALU_SLTU: result_o = word_t'(operand_a_i < operand_b_i);
      ALU_XOR: result_o = operand_a_i ^ operand_b_i;
      ALU_SRL: result_o = operand_a_i >> operand_b_i[4:0];
      ALU_SRA: result_o = word_t'($signed(operand_a_i) >>> operand_b_i[4:0]);
      ALU_OR: result_o = operand_a_i | operand_b_i;
      ALU_AND: result_o = operand_a_i & operand_b_i;
      ALU_PASS_A: result_o = operand_a_i;
      ALU_PASS_B: result_o = operand_b_i;
      default: result_o = '0;
    endcase
  end

endmodule
