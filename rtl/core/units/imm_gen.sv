// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 按指令格式生成立即数，供 ALU 和 ID 的 PC 相对计算共用。
module imm_gen
  import riscv_core_pkg::*;
(
  input instr_t instr_i,
  output word_t imm_o
);

  always_comb begin
    imm_o = '0;
    case (opcode_e'(instr_i[6:0]))
      // 移位运算只读取 operand_b[4:0]，同样使用 I 型立即数，无需单独译码。
      OPC_LOAD, OPC_JALR, OPC_OP_IMM: imm_o = {{20{instr_i[31]}}, instr_i[31:20]};
      OPC_STORE: imm_o = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
      OPC_BRANCH: imm_o = {{19{instr_i[31]}}, instr_i[31], instr_i[7], instr_i[30:25],
                          instr_i[11:8], 1'b0};
      OPC_LUI, OPC_AUIPC: imm_o = {instr_i[31:12], 12'b0};
      OPC_JAL: imm_o = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12], instr_i[20],
                       instr_i[30:21], 1'b0};
      OPC_SYSTEM: begin
        if (instr_i[14:12] inside {3'b101, 3'b110, 3'b111})
          imm_o = word_t'(instr_i[19:15]);
      end
      default: ;
    endcase
  end

endmodule
