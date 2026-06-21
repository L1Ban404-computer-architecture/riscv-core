// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module decoder (
  input instr_t instr_i,
  output reg_addr_bus_t reg_addr_o,
  output imm_type_e imm_type_o,
  output decode_ctrl_bus_t ctrl_o
);

  opcode_e opcode;
  funct3_t funct3;
  funct7_t funct7;

  always_comb begin
    opcode = opcode_e'(instr_i[6:0]);
    funct3 = instr_i[14:12];
    funct7 = instr_i[31:25];

    reg_addr_o.rs1_addr = instr_i[19:15];
    reg_addr_o.rs2_addr = instr_i[24:20];
    reg_addr_o.rd_addr = instr_i[11:7];

    imm_type_o = IMM_NONE;
    ctrl_o = '0;
    ctrl_o.alu_op = ALU_ADD;
    ctrl_o.op_a_sel = OP_A_RS1;
    ctrl_o.op_b_sel = OP_B_RS2;
    ctrl_o.branch_op = BR_NONE;
    ctrl_o.mem_cmd = MEM_NONE;
    ctrl_o.mem_size = MEM_SIZE_WORD;
    ctrl_o.wb_sel = WB_NONE;
    ctrl_o.illegal_instr = 1'b1;

    case (opcode)
      OPC_LUI: begin
        imm_type_o = IMM_U;
        ctrl_o.alu_op = ALU_PASS_B;
        ctrl_o.op_b_sel = OP_B_IMM;
        ctrl_o.wb_sel = WB_ALU;
        ctrl_o.rd_write = 1'b1;
        ctrl_o.illegal_instr = 1'b0;
      end

      OPC_AUIPC: begin
        imm_type_o = IMM_U;
        ctrl_o.op_a_sel = OP_A_PC;
        ctrl_o.op_b_sel = OP_B_IMM;
        ctrl_o.wb_sel = WB_ALU;
        ctrl_o.rd_write = 1'b1;
        ctrl_o.illegal_instr = 1'b0;
      end

      OPC_JAL: begin
        imm_type_o = IMM_J;
        ctrl_o.op_a_sel = OP_A_PC;
        ctrl_o.op_b_sel = OP_B_IMM;
        ctrl_o.branch_op = BR_JAL;
        ctrl_o.wb_sel = WB_PC4;
        ctrl_o.rd_write = 1'b1;
        ctrl_o.illegal_instr = 1'b0;
      end

      OPC_JALR: begin
        if (funct3 == 3'b000) begin
          imm_type_o = IMM_I;
          ctrl_o.op_b_sel = OP_B_IMM;
          ctrl_o.branch_op = BR_JALR;
          ctrl_o.wb_sel = WB_PC4;
          ctrl_o.rd_write = 1'b1;
          ctrl_o.illegal_instr = 1'b0;
        end
      end

      OPC_BRANCH: begin
        imm_type_o = IMM_B;
        ctrl_o.op_a_sel = OP_A_PC;
        ctrl_o.op_b_sel = OP_B_IMM;
        case (funct3)
          3'b000: ctrl_o.branch_op = BR_BEQ;
          3'b001: ctrl_o.branch_op = BR_BNE;
          3'b100: ctrl_o.branch_op = BR_BLT;
          3'b101: ctrl_o.branch_op = BR_BGE;
          3'b110: ctrl_o.branch_op = BR_BLTU;
          3'b111: ctrl_o.branch_op = BR_BGEU;
          default: ctrl_o.branch_op = BR_NONE;
        endcase
        ctrl_o.illegal_instr = (ctrl_o.branch_op == BR_NONE);
      end

      OPC_LOAD: begin
        imm_type_o = IMM_I;
        ctrl_o.op_b_sel = OP_B_IMM;
        ctrl_o.mem_cmd = MEM_LOAD;
        ctrl_o.wb_sel = WB_MEM;
        ctrl_o.rd_write = 1'b1;
        case (funct3)
          3'b000: begin
            ctrl_o.mem_size = MEM_SIZE_BYTE;
            ctrl_o.mem_sign_ext = 1'b1;
          end
          3'b001: begin
            ctrl_o.mem_size = MEM_SIZE_HALF;
            ctrl_o.mem_sign_ext = 1'b1;
          end
          3'b010: begin
            ctrl_o.mem_size = MEM_SIZE_WORD;
            ctrl_o.mem_sign_ext = 1'b1;
          end
          3'b100: begin
            ctrl_o.mem_size = MEM_SIZE_BYTE;
            ctrl_o.mem_sign_ext = 1'b0;
          end
          3'b101: begin
            ctrl_o.mem_size = MEM_SIZE_HALF;
            ctrl_o.mem_sign_ext = 1'b0;
          end
          default: begin
            ctrl_o.mem_cmd = MEM_NONE;
            ctrl_o.wb_sel = WB_NONE;
            ctrl_o.rd_write = 1'b0;
          end
        endcase
        ctrl_o.illegal_instr = (ctrl_o.mem_cmd == MEM_NONE);
      end

      OPC_STORE: begin
        imm_type_o = IMM_S;
        ctrl_o.op_b_sel = OP_B_IMM;
        ctrl_o.mem_cmd = MEM_STORE;
        case (funct3)
          3'b000: ctrl_o.mem_size = MEM_SIZE_BYTE;
          3'b001: ctrl_o.mem_size = MEM_SIZE_HALF;
          3'b010: ctrl_o.mem_size = MEM_SIZE_WORD;
          default: ctrl_o.mem_cmd = MEM_NONE;
        endcase
        ctrl_o.illegal_instr = (ctrl_o.mem_cmd == MEM_NONE);
      end

      OPC_OP_IMM: begin
        imm_type_o = IMM_I;
        ctrl_o.op_b_sel = OP_B_IMM;
        ctrl_o.wb_sel = WB_ALU;
        ctrl_o.rd_write = 1'b1;
        case (funct3)
          3'b000: begin
            ctrl_o.alu_op = ALU_ADD;
            ctrl_o.illegal_instr = 1'b0;
          end
          3'b010: begin
            ctrl_o.alu_op = ALU_SLT;
            ctrl_o.illegal_instr = 1'b0;
          end
          3'b011: begin
            ctrl_o.alu_op = ALU_SLTU;
            ctrl_o.illegal_instr = 1'b0;
          end
          3'b100: begin
            ctrl_o.alu_op = ALU_XOR;
            ctrl_o.illegal_instr = 1'b0;
          end
          3'b110: begin
            ctrl_o.alu_op = ALU_OR;
            ctrl_o.illegal_instr = 1'b0;
          end
          3'b111: begin
            ctrl_o.alu_op = ALU_AND;
            ctrl_o.illegal_instr = 1'b0;
          end
          3'b001: begin
            ctrl_o.alu_op = ALU_SLL;
            ctrl_o.illegal_instr = (funct7 != 7'b0000000);
          end
          3'b101: begin
            if (funct7 == 7'b0000000) begin
              ctrl_o.alu_op = ALU_SRL;
              ctrl_o.illegal_instr = 1'b0;
            end else if (funct7 == 7'b0100000) begin
              ctrl_o.alu_op = ALU_SRA;
              ctrl_o.illegal_instr = 1'b0;
            end
          end
          default: ;
        endcase
        if (ctrl_o.illegal_instr) begin
          ctrl_o.wb_sel = WB_NONE;
          ctrl_o.rd_write = 1'b0;
        end
      end

      OPC_OP: begin
        ctrl_o.wb_sel = WB_ALU;
        ctrl_o.rd_write = 1'b1;
        if (funct7 == 7'b0000000) begin
          case (funct3)
            3'b000: begin
              ctrl_o.alu_op = ALU_ADD;
              ctrl_o.illegal_instr = 1'b0;
            end
            3'b001: begin
              ctrl_o.alu_op = ALU_SLL;
              ctrl_o.illegal_instr = 1'b0;
            end
            3'b010: begin
              ctrl_o.alu_op = ALU_SLT;
              ctrl_o.illegal_instr = 1'b0;
            end
            3'b011: begin
              ctrl_o.alu_op = ALU_SLTU;
              ctrl_o.illegal_instr = 1'b0;
            end
            3'b100: begin
              ctrl_o.alu_op = ALU_XOR;
              ctrl_o.illegal_instr = 1'b0;
            end
            3'b101: begin
              ctrl_o.alu_op = ALU_SRL;
              ctrl_o.illegal_instr = 1'b0;
            end
            3'b110: begin
              ctrl_o.alu_op = ALU_OR;
              ctrl_o.illegal_instr = 1'b0;
            end
            3'b111: begin
              ctrl_o.alu_op = ALU_AND;
              ctrl_o.illegal_instr = 1'b0;
            end
            default: ;
          endcase
        end else if (funct7 == 7'b0100000) begin
          case (funct3)
            3'b000: begin
              ctrl_o.alu_op = ALU_SUB;
              ctrl_o.illegal_instr = 1'b0;
            end
            3'b101: begin
              ctrl_o.alu_op = ALU_SRA;
              ctrl_o.illegal_instr = 1'b0;
            end
            default: ;
          endcase
        end
        if (ctrl_o.illegal_instr) begin
          ctrl_o.wb_sel = WB_NONE;
          ctrl_o.rd_write = 1'b0;
        end
      end

      // FENCE 在本核的顺序存储接口上不需要额外硬件动作，可作为合法空操作
      // 退休。保留字段必须为零；FENCE.I 属于单独的 Zifencei 扩展。
      OPC_MISC_MEM: begin
        if ((funct3 == 3'b000) && (instr_i[19:15] == ZeroReg) && (instr_i[11:7] == ZeroReg)) begin
          ctrl_o.illegal_instr = 1'b0;
        end
      end

      // SYSTEM 的异常/CSR 语义尚未进入流水控制总线，暂按非法指令处理，
      // 避免错误地把 ECALL、EBREAK 或 CSR 指令当作空操作退休。显式列出
      // OPC_SYSTEM，保证 unique case 完整覆盖 opcode_e 的所有枚举值。
      OPC_SYSTEM: ;

      // 非法的 7-bit opcode 编码由枚举 cast 后落入 default。
      default: ;
    endcase
  end

endmodule
