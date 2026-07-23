// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module decoder (
  input instr_t instr_i,
  output reg_addr_bus_t reg_addr_o,
  output imm_type_e imm_type_o,
  output execute_ctrl_bus_t ctrl_o,
  output logic illegal_o
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
    ctrl_o.csr_cmd = CSR_NONE;
    ctrl_o.system_op = SYS_NONE;
    illegal_o = 1'b1;

    case (opcode)
      OPC_LUI: begin
        imm_type_o = IMM_U;
        ctrl_o.alu_op = ALU_PASS_B;
        ctrl_o.op_b_sel = OP_B_IMM;
        ctrl_o.wb_sel = WB_ALU;
        ctrl_o.rd_write = 1'b1;
        illegal_o = 1'b0;
      end

      OPC_AUIPC: begin
        imm_type_o = IMM_U;
        ctrl_o.op_a_sel = OP_A_PC;
        ctrl_o.op_b_sel = OP_B_IMM;
        ctrl_o.wb_sel = WB_ALU;
        ctrl_o.rd_write = 1'b1;
        illegal_o = 1'b0;
      end

      OPC_JAL: begin
        imm_type_o = IMM_J;
        ctrl_o.op_a_sel = OP_A_PC;
        ctrl_o.op_b_sel = OP_B_IMM;
        ctrl_o.branch_op = BR_JAL;
        ctrl_o.wb_sel = WB_PC4;
        ctrl_o.rd_write = 1'b1;
        illegal_o = 1'b0;
      end

      OPC_JALR: begin
        if (funct3 == 3'b000) begin
          imm_type_o = IMM_I;
          ctrl_o.op_b_sel = OP_B_IMM;
          ctrl_o.branch_op = BR_JALR;
          ctrl_o.wb_sel = WB_PC4;
          ctrl_o.rd_write = 1'b1;
          illegal_o = 1'b0;
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
        illegal_o = (ctrl_o.branch_op == BR_NONE);
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
        illegal_o = (ctrl_o.mem_cmd == MEM_NONE);
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
        illegal_o = (ctrl_o.mem_cmd == MEM_NONE);
      end

      OPC_OP_IMM: begin
        imm_type_o = IMM_I;
        ctrl_o.op_b_sel = OP_B_IMM;
        ctrl_o.wb_sel = WB_ALU;
        ctrl_o.rd_write = 1'b1;
        case (funct3)
          3'b000: begin
            ctrl_o.alu_op = ALU_ADD;
            illegal_o = 1'b0;
          end
          3'b010: begin
            ctrl_o.alu_op = ALU_SLT;
            illegal_o = 1'b0;
          end
          3'b011: begin
            ctrl_o.alu_op = ALU_SLTU;
            illegal_o = 1'b0;
          end
          3'b100: begin
            ctrl_o.alu_op = ALU_XOR;
            illegal_o = 1'b0;
          end
          3'b110: begin
            ctrl_o.alu_op = ALU_OR;
            illegal_o = 1'b0;
          end
          3'b111: begin
            ctrl_o.alu_op = ALU_AND;
            illegal_o = 1'b0;
          end
          3'b001: begin
            ctrl_o.alu_op = ALU_SLL;
            illegal_o = (funct7 != 7'b0000000);
          end
          3'b101: begin
            if (funct7 == 7'b0000000) begin
              ctrl_o.alu_op = ALU_SRL;
              illegal_o = 1'b0;
            end else if (funct7 == 7'b0100000) begin
              ctrl_o.alu_op = ALU_SRA;
              illegal_o = 1'b0;
            end
          end
          default: ;
        endcase
        if (illegal_o) begin
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
              illegal_o = 1'b0;
            end
            3'b001: begin
              ctrl_o.alu_op = ALU_SLL;
              illegal_o = 1'b0;
            end
            3'b010: begin
              ctrl_o.alu_op = ALU_SLT;
              illegal_o = 1'b0;
            end
            3'b011: begin
              ctrl_o.alu_op = ALU_SLTU;
              illegal_o = 1'b0;
            end
            3'b100: begin
              ctrl_o.alu_op = ALU_XOR;
              illegal_o = 1'b0;
            end
            3'b101: begin
              ctrl_o.alu_op = ALU_SRL;
              illegal_o = 1'b0;
            end
            3'b110: begin
              ctrl_o.alu_op = ALU_OR;
              illegal_o = 1'b0;
            end
            3'b111: begin
              ctrl_o.alu_op = ALU_AND;
              illegal_o = 1'b0;
            end
            default: ;
          endcase
        end else if (funct7 == 7'b0100000) begin
          case (funct3)
            3'b000: begin
              ctrl_o.alu_op = ALU_SUB;
              illegal_o = 1'b0;
            end
            3'b101: begin
              ctrl_o.alu_op = ALU_SRA;
              illegal_o = 1'b0;
            end
            default: ;
          endcase
        end
        if (illegal_o) begin
          ctrl_o.wb_sel = WB_NONE;
          ctrl_o.rd_write = 1'b0;
        end
      end

      // FENCE 在本核的严格顺序数据通路上按保守全栅栏实现，不需要额外动作。
      // RV32I 要求忽略 rs1/rd 及保留的 fm/pred/succ 配置；FENCE.I 属于
      // 单独的 Zifencei 扩展，仍作为非法指令处理。
      OPC_MISC_MEM: begin
        if (funct3 == 3'b000) illegal_o = 1'b0;
      end

      OPC_SYSTEM: begin
        ctrl_o.csr_addr = instr_i[31:20];
        if (funct3 == 3'b000) begin
          ctrl_o.serialize = 1'b1;
          unique case (instr_i)
            32'h0000_0073: begin
              ctrl_o.system_op = SYS_ECALL;
              illegal_o = 1'b0;
            end
            32'h0010_0073: begin
              ctrl_o.system_op = SYS_EBREAK;
              illegal_o = 1'b0;
            end
            32'h3020_0073: begin
              ctrl_o.system_op = SYS_MRET;
              illegal_o = 1'b0;
            end
            default: ;
          endcase
        end else begin
          ctrl_o.serialize = 1'b1;
          ctrl_o.wb_sel = WB_CSR;
          ctrl_o.rd_write = 1'b1;
          ctrl_o.csr_use_imm = funct3[2];
          imm_type_o = funct3[2] ? IMM_Z : IMM_NONE;

          unique case (funct3[1:0])
            2'b01: ctrl_o.csr_cmd = CSR_RW;
            2'b10: ctrl_o.csr_cmd = CSR_RS;
            2'b11: ctrl_o.csr_cmd = CSR_RC;
            default: ctrl_o.csr_cmd = CSR_NONE;
          endcase

          // 地址实现性由 CSR 单元的组合读端口统一判断；decoder 只负责
          // Zicsr 的 funct3 语法。
          illegal_o = (ctrl_o.csr_cmd == CSR_NONE);

          if (illegal_o) begin
            ctrl_o.csr_cmd = CSR_NONE;
            ctrl_o.wb_sel = WB_NONE;
            ctrl_o.rd_write = 1'b0;
          end
        end
      end

      // 非法的 7-bit opcode 编码由枚举 cast 后落入 default。
      default: ;
    endcase
  end

endmodule
