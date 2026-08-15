// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// RV32I/Zicsr 组合译码器，将指令编码转换为流水线执行控制。
module decoder
  import riscv_core_pkg::*;
(
  // 指令与译码结果
  input instr_t instr_i,
  output decode_result_t decode_o
);

  opcode_e opcode;
  funct3_t funct3;
  funct7_t funct7;

  always_comb begin
    opcode = opcode_e'(instr_i[6:0]);
    funct3 = instr_i[14:12];
    funct7 = instr_i[31:25];

    decode_o = '0;
    decode_o.reg_addr.rs1_addr = instr_i[19:15];
    decode_o.reg_addr.rs2_addr = instr_i[24:20];
    decode_o.reg_addr.rd_addr = instr_i[11:7];

    decode_o.imm_type = IMM_NONE;

    decode_o.ctrl.alu_op = ALU_ADD;
    decode_o.ctrl.mem_sign_ext = 1'b0;
    decode_o.ctrl.rd_write = 1'b0;
    decode_o.ctrl.csr_use_imm = 1'b0;
    decode_o.ctrl.csr_addr = '0;
    decode_o.ctrl.serialize = 1'b0;
    decode_o.ctrl.op_a_sel = OP_A_RS1;
    decode_o.ctrl.op_b_sel = OP_B_RS2;
    decode_o.ctrl.branch_op = BR_NONE;
    decode_o.ctrl.mem_cmd = MEM_NONE;
    decode_o.ctrl.mem_size = MEM_SIZE_WORD;
    decode_o.ctrl.wb_sel = WB_NONE;
    decode_o.ctrl.csr_cmd = CSR_NONE;
    decode_o.ctrl.system_op = SYS_NONE;
    decode_o.illegal = 1'b1;

    case (opcode)
      OPC_LUI: begin
        decode_o.imm_type = IMM_U;
        decode_o.ctrl.alu_op = ALU_PASS_B;
        decode_o.ctrl.op_b_sel = OP_B_IMM;
        decode_o.ctrl.wb_sel = WB_ALU;
        decode_o.ctrl.rd_write = 1'b1;
        decode_o.illegal = 1'b0;
      end

      OPC_AUIPC: begin
        decode_o.imm_type = IMM_U;
        decode_o.ctrl.op_a_sel = OP_A_PC;
        decode_o.ctrl.op_b_sel = OP_B_IMM;
        decode_o.ctrl.wb_sel = WB_ALU;
        decode_o.ctrl.rd_write = 1'b1;
        decode_o.illegal = 1'b0;
      end

      OPC_JAL: begin
        decode_o.imm_type = IMM_J;
        decode_o.ctrl.op_a_sel = OP_A_PC;
        decode_o.ctrl.op_b_sel = OP_B_IMM;
        decode_o.ctrl.branch_op = BR_JAL;
        decode_o.ctrl.wb_sel = WB_PC4;
        decode_o.ctrl.rd_write = 1'b1;
        decode_o.illegal = 1'b0;
      end

      OPC_JALR: begin
        if (funct3 == 3'b000) begin
          decode_o.imm_type = IMM_I;
          decode_o.ctrl.op_b_sel = OP_B_IMM;
          decode_o.ctrl.branch_op = BR_JALR;
          decode_o.ctrl.wb_sel = WB_PC4;
          decode_o.ctrl.rd_write = 1'b1;
          decode_o.illegal = 1'b0;
        end
      end

      OPC_BRANCH: begin
        decode_o.imm_type = IMM_B;
        decode_o.ctrl.op_a_sel = OP_A_PC;
        decode_o.ctrl.op_b_sel = OP_B_IMM;
        case (funct3)
          3'b000: decode_o.ctrl.branch_op = BR_BEQ;
          3'b001: decode_o.ctrl.branch_op = BR_BNE;
          3'b100: decode_o.ctrl.branch_op = BR_BLT;
          3'b101: decode_o.ctrl.branch_op = BR_BGE;
          3'b110: decode_o.ctrl.branch_op = BR_BLTU;
          3'b111: decode_o.ctrl.branch_op = BR_BGEU;
          default: decode_o.ctrl.branch_op = BR_NONE;
        endcase
        decode_o.illegal = (decode_o.ctrl.branch_op == BR_NONE);
      end

      OPC_LOAD: begin
        decode_o.imm_type = IMM_I;
        decode_o.ctrl.op_b_sel = OP_B_IMM;
        decode_o.ctrl.mem_cmd = MEM_LOAD;
        decode_o.ctrl.wb_sel = WB_MEM;
        decode_o.ctrl.rd_write = 1'b1;
        case (funct3)
          3'b000: begin
            decode_o.ctrl.mem_size = MEM_SIZE_BYTE;
            decode_o.ctrl.mem_sign_ext = 1'b1;
          end
          3'b001: begin
            decode_o.ctrl.mem_size = MEM_SIZE_HALF;
            decode_o.ctrl.mem_sign_ext = 1'b1;
          end
          3'b010: begin
            decode_o.ctrl.mem_size = MEM_SIZE_WORD;
            decode_o.ctrl.mem_sign_ext = 1'b1;
          end
          3'b100: begin
            decode_o.ctrl.mem_size = MEM_SIZE_BYTE;
            decode_o.ctrl.mem_sign_ext = 1'b0;
          end
          3'b101: begin
            decode_o.ctrl.mem_size = MEM_SIZE_HALF;
            decode_o.ctrl.mem_sign_ext = 1'b0;
          end
          default: begin
            decode_o.ctrl.mem_cmd = MEM_NONE;
            decode_o.ctrl.wb_sel = WB_NONE;
            decode_o.ctrl.rd_write = 1'b0;
          end
        endcase
        decode_o.illegal = (decode_o.ctrl.mem_cmd == MEM_NONE);
      end

      OPC_STORE: begin
        decode_o.imm_type = IMM_S;
        decode_o.ctrl.op_b_sel = OP_B_IMM;
        decode_o.ctrl.mem_cmd = MEM_STORE;
        case (funct3)
          3'b000: decode_o.ctrl.mem_size = MEM_SIZE_BYTE;
          3'b001: decode_o.ctrl.mem_size = MEM_SIZE_HALF;
          3'b010: decode_o.ctrl.mem_size = MEM_SIZE_WORD;
          default: decode_o.ctrl.mem_cmd = MEM_NONE;
        endcase
        decode_o.illegal = (decode_o.ctrl.mem_cmd == MEM_NONE);
      end

      OPC_OP_IMM: begin
        decode_o.imm_type = IMM_I;
        decode_o.ctrl.op_b_sel = OP_B_IMM;
        decode_o.ctrl.wb_sel = WB_ALU;
        decode_o.ctrl.rd_write = 1'b1;
        case (funct3)
          3'b000: begin
            decode_o.ctrl.alu_op = ALU_ADD;
            decode_o.illegal = 1'b0;
          end
          3'b010: begin
            decode_o.ctrl.alu_op = ALU_SLT;
            decode_o.illegal = 1'b0;
          end
          3'b011: begin
            decode_o.ctrl.alu_op = ALU_SLTU;
            decode_o.illegal = 1'b0;
          end
          3'b100: begin
            decode_o.ctrl.alu_op = ALU_XOR;
            decode_o.illegal = 1'b0;
          end
          3'b110: begin
            decode_o.ctrl.alu_op = ALU_OR;
            decode_o.illegal = 1'b0;
          end
          3'b111: begin
            decode_o.ctrl.alu_op = ALU_AND;
            decode_o.illegal = 1'b0;
          end
          3'b001: begin
            decode_o.ctrl.alu_op = ALU_SLL;
            decode_o.illegal = (funct7 != 7'b0000000);
          end
          3'b101: begin
            if (funct7 == 7'b0000000) begin
              decode_o.ctrl.alu_op = ALU_SRL;
              decode_o.illegal = 1'b0;
            end else if (funct7 == 7'b0100000) begin
              decode_o.ctrl.alu_op = ALU_SRA;
              decode_o.illegal = 1'b0;
            end
          end
          default: ;
        endcase
        if (decode_o.illegal) begin
          decode_o.ctrl.wb_sel = WB_NONE;
          decode_o.ctrl.rd_write = 1'b0;
        end
      end

      OPC_OP: begin
        decode_o.ctrl.wb_sel = WB_ALU;
        decode_o.ctrl.rd_write = 1'b1;
        if (funct7 == 7'b0000000) begin
          case (funct3)
            3'b000: begin
              decode_o.ctrl.alu_op = ALU_ADD;
              decode_o.illegal = 1'b0;
            end
            3'b001: begin
              decode_o.ctrl.alu_op = ALU_SLL;
              decode_o.illegal = 1'b0;
            end
            3'b010: begin
              decode_o.ctrl.alu_op = ALU_SLT;
              decode_o.illegal = 1'b0;
            end
            3'b011: begin
              decode_o.ctrl.alu_op = ALU_SLTU;
              decode_o.illegal = 1'b0;
            end
            3'b100: begin
              decode_o.ctrl.alu_op = ALU_XOR;
              decode_o.illegal = 1'b0;
            end
            3'b101: begin
              decode_o.ctrl.alu_op = ALU_SRL;
              decode_o.illegal = 1'b0;
            end
            3'b110: begin
              decode_o.ctrl.alu_op = ALU_OR;
              decode_o.illegal = 1'b0;
            end
            3'b111: begin
              decode_o.ctrl.alu_op = ALU_AND;
              decode_o.illegal = 1'b0;
            end
            default: ;
          endcase
        end else if (funct7 == 7'b0100000) begin
          case (funct3)
            3'b000: begin
              decode_o.ctrl.alu_op = ALU_SUB;
              decode_o.illegal = 1'b0;
            end
            3'b101: begin
              decode_o.ctrl.alu_op = ALU_SRA;
              decode_o.illegal = 1'b0;
            end
            default: ;
          endcase
        end
        if (decode_o.illegal) begin
          decode_o.ctrl.wb_sel = WB_NONE;
          decode_o.ctrl.rd_write = 1'b0;
        end
      end

      // FENCE 在本核的严格顺序数据通路上按保守全栅栏实现，不需要额外动作。
      // RV32I 要求忽略 rs1/rd 及保留的 fm/pred/succ 配置；FENCE.I 属于
      // 单独的 Zifencei 扩展，仍作为非法指令处理。
      OPC_MISC_MEM: begin
        if (funct3 == 3'b000) decode_o.illegal = 1'b0;
      end

      OPC_SYSTEM: begin
        decode_o.ctrl.csr_addr = instr_i[31:20];
        if (funct3 == 3'b000) begin
          decode_o.ctrl.serialize = 1'b1;
          unique case (instr_i)
            32'h0000_0073: begin
              decode_o.ctrl.system_op = SYS_ECALL;
              decode_o.illegal = 1'b0;
            end
            32'h0010_0073: begin
              decode_o.ctrl.system_op = SYS_EBREAK;
              decode_o.illegal = 1'b0;
            end
            32'h3020_0073: begin
              decode_o.ctrl.system_op = SYS_MRET;
              decode_o.illegal = 1'b0;
            end
            default: ;
          endcase
        end else begin
          decode_o.ctrl.serialize = 1'b1;
          decode_o.ctrl.wb_sel = WB_CSR;
          decode_o.ctrl.rd_write = 1'b1;
          decode_o.ctrl.csr_use_imm = funct3[2];
          decode_o.imm_type = funct3[2] ? IMM_Z : IMM_NONE;

          unique case (funct3[1:0])
            2'b01: decode_o.ctrl.csr_cmd = CSR_RW;
            2'b10: decode_o.ctrl.csr_cmd = CSR_RS;
            2'b11: decode_o.ctrl.csr_cmd = CSR_RC;
            default: decode_o.ctrl.csr_cmd = CSR_NONE;
          endcase

          // 地址实现性由 CSR 单元的组合读端口统一判断；decoder 只负责
          // Zicsr 的 funct3 语法。
          decode_o.illegal = (decode_o.ctrl.csr_cmd == CSR_NONE);

          if (decode_o.illegal) begin
            decode_o.ctrl.csr_cmd = CSR_NONE;
            decode_o.ctrl.wb_sel = WB_NONE;
            decode_o.ctrl.rd_write = 1'b0;
          end
        end
      end

      // 非法的 7-bit opcode 编码由枚举 cast 后落入 default。
      default: ;
    endcase
  end

endmodule
