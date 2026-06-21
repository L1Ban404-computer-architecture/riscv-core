// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module alu (
  input alu_op_e alu_op_i,
  input word_t operand_a_i,
  input word_t operand_b_i,
  output word_t result_o
);

  always_comb begin
    case (alu_op_i)
      ALU_ADD: result_o = operand_a_i + operand_b_i;
      ALU_SUB: result_o = operand_a_i - operand_b_i;
      ALU_SLL: result_o = operand_a_i << operand_b_i[4:0];
      ALU_SLT: result_o = word_t'($signed(operand_a_i) < $signed(operand_b_i));
      ALU_SLTU: result_o = word_t'(operand_a_i < operand_b_i);
      ALU_XOR: result_o = operand_a_i ^ operand_b_i;
      ALU_SRL: result_o = operand_a_i >> operand_b_i[4:0];
      ALU_SRA: result_o = word_t'($signed(operand_a_i) >>> operand_b_i[4:0]);
      ALU_OR: result_o = operand_a_i | operand_b_i;
      ALU_AND: result_o = operand_a_i & operand_b_i;
      ALU_PASS_B: result_o = operand_b_i;
      default: result_o = '0;
    endcase
  end

endmodule
