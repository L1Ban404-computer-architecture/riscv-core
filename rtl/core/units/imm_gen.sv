// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 立即数直接由指令字段生成，与完整合法性译码并行，缩短 ID 的 PC 相对路径。
module imm_gen
  import riscv_core_pkg::*;
(
  input instr_t instr_i,
  output word_t imm_o,
  output word_t pc_offset_o
);

  word_t branch_imm, jump_imm, upper_imm;

  assign branch_imm = {{19{instr_i[31]}}, instr_i[31], instr_i[7], instr_i[30:25],
                       instr_i[11:8], 1'b0};
  assign jump_imm = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12], instr_i[20],
                     instr_i[30:21], 1'b0};
  assign upper_imm = {instr_i[31:12], 12'b0};
  // PC 相对路径独立选择 AUIPC/B/J 的偏移，不等待通用立即数选择。
  always_comb begin
    case (opcode_e'(instr_i[6:0]))
      OPC_AUIPC: pc_offset_o = upper_imm;
      OPC_BRANCH: pc_offset_o = branch_imm;
      OPC_JAL: pc_offset_o = jump_imm;
      default: pc_offset_o = '0;
    endcase
  end

  always_comb begin
    imm_o = '0;
    case (opcode_e'(instr_i[6:0]))
      OPC_LOAD, OPC_JALR: imm_o = {{20{instr_i[31]}}, instr_i[31:20]};
      OPC_OP_IMM: begin
        if (instr_i[14:12] inside {3'b001, 3'b101})
          imm_o = word_t'(instr_i[24:20]);
        else imm_o = {{20{instr_i[31]}}, instr_i[31:20]};
      end
      OPC_STORE: imm_o = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
      OPC_BRANCH: imm_o = branch_imm;
      OPC_LUI, OPC_AUIPC: imm_o = upper_imm;
      OPC_JAL: imm_o = jump_imm;
      OPC_SYSTEM: begin
        if (instr_i[14:12] inside {3'b101, 3'b110, 3'b111})
          imm_o = word_t'(instr_i[19:15]);
      end
      default: ;
    endcase
  end

endmodule
