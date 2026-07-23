// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module branch_unit (
  input logic execute_fire_i,
  input logic illegal_instr_i,
  input branch_op_e branch_op_i,
  input word_t rs1_value_i,
  input word_t rs2_value_i,
  input word_t alu_target_i,
  output redirect_bus_t redirect_o
);

  logic taken;

  always_comb begin
    taken = 1'b0;
    case (branch_op_i)
      BR_NONE: taken = 1'b0;
      BR_JAL, BR_JALR: taken = 1'b1;
      BR_BEQ: taken = (rs1_value_i == rs2_value_i);
      BR_BNE: taken = (rs1_value_i != rs2_value_i);
      BR_BLT: taken = ($signed(rs1_value_i) < $signed(rs2_value_i));
      BR_BGE: taken = ($signed(rs1_value_i) >= $signed(rs2_value_i));
      BR_BLTU: taken = (rs1_value_i < rs2_value_i);
      BR_BGEU: taken = (rs1_value_i >= rs2_value_i);
      default: ;
    endcase

    redirect_o = '0;
    redirect_o.valid = execute_fire_i && taken && !illegal_instr_i;

    // RISC-V 要求 JALR 目标地址的最低位清零；其他跳转目标直接使用
    // ALU 计算得到的 PC-relative 地址。
    redirect_o.target_pc = (branch_op_i == BR_JALR) ? (alu_target_i & word_t'(~1)) : alu_target_i;

  end

endmodule
