// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// RV32I/E/Zicsr/Zifencei 译码：分别生成源寄存器、执行控制和提交控制。
module decoder
  import riscv_core_pkg::*;
(
  input instr_t instr_i,
  output decode_result_t decode_o
);

  opcode_e opcode;
  funct3_t funct3;
  funct7_t funct7;

  assign opcode = opcode_e'(instr_i[6:0]);
  assign funct3 = instr_i[14:12];
  assign funct7 = instr_i[31:25];

  always_comb begin
    decode_o = '0;
    decode_o.reg_addr.rs1_addr = instr_i[19:15];
    decode_o.reg_addr.rs2_addr = instr_i[24:20];
    decode_o.gpr.addr = instr_i[11:7];
    decode_o.ctrl.mem_size = MEM_SIZE_WORD;
    // 默认 ADD/ALU/RS2；指令类别只覆盖需要改变的执行语义。
    decode_o.illegal = 1'b1;

    case (opcode)
      OPC_LUI: begin
        decode_o.ctrl.op_b_sel = OP_B_IMM;
        decode_o.ctrl.alu_op = ALU_PASS_B;
        decode_o.gpr.write = 1'b1;
        decode_o.illegal = 1'b0;
      end

      OPC_AUIPC: begin
        decode_o.ctrl.result_source = RESULT_PC_RELATIVE;
        decode_o.gpr.write = 1'b1;
        decode_o.illegal = 1'b0;
      end

      OPC_JAL: begin
        decode_o.ctrl.result_source = RESULT_PC4;
        decode_o.ctrl.branch_op = BR_JAL;
        decode_o.gpr.write = 1'b1;
        decode_o.illegal = 1'b0;
      end

      OPC_JALR: begin
        decode_o.ctrl.op_b_sel = OP_B_IMM;
        decode_o.ctrl.result_source = RESULT_PC4;
        decode_o.ctrl.branch_op = BR_JALR;
        decode_o.gpr.write = 1'b1;
        decode_o.illegal = (funct3 != 3'b000);
      end

      OPC_BRANCH: begin
        // 条件分支由 branch_unit 直接比较两个源寄存器。
        case (funct3)
          3'b000: decode_o.ctrl.branch_op = BR_BEQ;
          3'b001: decode_o.ctrl.branch_op = BR_BNE;
          3'b100: decode_o.ctrl.branch_op = BR_BLT;
          3'b101: decode_o.ctrl.branch_op = BR_BGE;
          3'b110: decode_o.ctrl.branch_op = BR_BLTU;
          3'b111: decode_o.ctrl.branch_op = BR_BGEU;
          default: ;
        endcase
        decode_o.illegal = (decode_o.ctrl.branch_op == BR_NONE);
      end

      OPC_LOAD: begin
        decode_o.ctrl.op_b_sel = OP_B_IMM;
        decode_o.ctrl.mem_cmd = MEM_LOAD;
        decode_o.ctrl.mem_sign_ext = !funct3[2];
        decode_o.gpr.write = 1'b1;
        case (funct3)
          3'b000, 3'b100: decode_o.ctrl.mem_size = MEM_SIZE_BYTE;
          3'b001, 3'b101: decode_o.ctrl.mem_size = MEM_SIZE_HALF;
          3'b010: decode_o.ctrl.mem_size = MEM_SIZE_WORD;
          default: decode_o.ctrl.mem_cmd = MEM_NONE;
        endcase
        decode_o.illegal = (decode_o.ctrl.mem_cmd == MEM_NONE);
      end

      OPC_STORE: begin
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

      // 两类整数运算共用 funct3，只在来源和 funct7 合法性上区分。
      OPC_OP, OPC_OP_IMM: begin
        decode_o.gpr.write = 1'b1;
        decode_o.ctrl.op_b_sel = (opcode == OPC_OP_IMM) ? OP_B_IMM : OP_B_RS2;
        // funct3 直接对应八种基本运算，只有 SUB/SRA 需要覆盖基本操作。
        decode_o.ctrl.alu_op = alu_op_e'({1'b0, funct3});
        if ((opcode == OPC_OP) && (funct3 == 3'b000) && instr_i[30])
          decode_o.ctrl.alu_op = ALU_SUB;
        if ((funct3 == 3'b101) && instr_i[30]) decode_o.ctrl.alu_op = ALU_SRA;
        if (opcode == OPC_OP)
          decode_o.illegal = (funct7 != 7'b0000000) &&
              !((funct7 == 7'b0100000) && (funct3 inside {3'b000, 3'b101}));
        else if (funct3 == 3'b001)
          decode_o.illegal = (funct7 != 7'b0000000);
        else if (funct3 == 3'b101)
          decode_o.illegal = !(funct7 inside {7'b0000000, 7'b0100000});
        else decode_o.illegal = 1'b0;
      end

      // 严格顺序访存已满足 FENCE；FENCE.I 的保留字段忽略，动作留到 WB。
      OPC_MISC_MEM: begin
        case (funct3)
          3'b000: decode_o.illegal = 1'b0;
          3'b001: begin
            decode_o.commit.fence_i = 1'b1;
            decode_o.illegal = 1'b0;
          end
          default: ;
        endcase
      end

      OPC_SYSTEM: begin
        if (funct3 == 3'b000) begin
          case (instr_i)
            32'h0000_0073: begin
              decode_o.system_op = SYS_ECALL;
              decode_o.illegal = 1'b0;
            end
            32'h0010_0073: begin
              decode_o.system_op = SYS_EBREAK;
              decode_o.illegal = 1'b0;
            end
            32'h3020_0073: begin
              decode_o.commit.is_mret = 1'b1;
              decode_o.illegal = 1'b0;
            end
            default: ;
          endcase
        end else begin
          // CSR 的 value 来自 rs1 或 zimm；读改写及 GPR 旧值在 WB 产生。
          decode_o.gpr.write = 1'b1;
          decode_o.ctrl.alu_op = funct3[2] ? ALU_PASS_B : ALU_PASS_A;
          decode_o.ctrl.op_b_sel = OP_B_IMM;
          decode_o.commit.csr.index = csr_index(instr_i[31:20]);
          case (funct3[1:0])
            2'b01: decode_o.commit.csr.cmd = CSR_RW;
            2'b10: decode_o.commit.csr.cmd = CSR_RS;
            2'b11: decode_o.commit.csr.cmd = CSR_RC;
            default: ;
          endcase
          // RS/RC 是否写入取决于寄存器编号或 zimm，不取决于寄存器值。
          decode_o.commit.csr.write = (decode_o.commit.csr.cmd == CSR_RW) ||
              (instr_i[19:15] != '0);
          decode_o.illegal = (decode_o.commit.csr.cmd == CSR_NONE) ||
              (decode_o.commit.csr.index == CSR_IDX_INVALID) ||
              (decode_o.commit.csr.write && (instr_i[31:30] == 2'b11));
        end
      end

      default: ;
    endcase

    // store 的 rs2 用于写数据，即使 B 选择立即数，也必须参与前递。
    decode_o.reg_addr.rs1_used = (opcode inside
        {OPC_JALR, OPC_BRANCH, OPC_LOAD, OPC_STORE, OPC_OP_IMM, OPC_OP}) ||
        ((opcode == OPC_SYSTEM) && (decode_o.commit.csr.cmd != CSR_NONE) && !funct3[2]);
    decode_o.reg_addr.rs2_used = opcode inside {OPC_BRANCH, OPC_STORE, OPC_OP};
    // 只有 load 和 CSR 的 GPR 结果需要等后级，其余写入在 EX 就绪。
    decode_o.gpr.ready = decode_o.gpr.write && (decode_o.ctrl.mem_cmd != MEM_LOAD) &&
        (decode_o.commit.csr.cmd == CSR_NONE);
    if (Rve && ((decode_o.gpr.write && instr_i[11]) ||
                (decode_o.reg_addr.rs1_used && instr_i[19]) ||
                (decode_o.reg_addr.rs2_used && instr_i[24])))
      decode_o.illegal = 1'b1;
  end

endmodule
