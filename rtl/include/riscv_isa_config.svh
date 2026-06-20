// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef RISCV_ISA_CONFIG_SVH
`define RISCV_ISA_CONFIG_SVH

// RV32I 指令编码基础类型。这里只枚举 decoder 需要直接识别的 opcode，
// funct3/funct7 的具体组合留给 decoder 按指令类别解释。
typedef enum logic [6:0] {
  OPC_LOAD = 7'b0000011,
  OPC_MISC_MEM = 7'b0001111,
  OPC_OP_IMM = 7'b0010011,
  OPC_AUIPC = 7'b0010111,
  OPC_STORE = 7'b0100011,
  OPC_OP = 7'b0110011,
  OPC_LUI = 7'b0110111,
  OPC_BRANCH = 7'b1100011,
  OPC_JALR = 7'b1100111,
  OPC_JAL = 7'b1101111,
  OPC_SYSTEM = 7'b1110011
} opcode_e;

typedef logic [2:0] funct3_t;
typedef logic [6:0] funct7_t;

// ISA 指令经 decoder 归一化后的执行控制语义。
typedef enum logic [3:0] {
  ALU_ADD,
  ALU_SUB,
  ALU_SLL,
  ALU_SLT,
  ALU_SLTU,
  ALU_XOR,
  ALU_SRL,
  ALU_SRA,
  ALU_OR,
  ALU_AND,
  ALU_PASS_B
} alu_op_e;

typedef enum logic {
  OP_A_RS1,
  OP_A_PC
} op_a_sel_e;

typedef enum logic {
  OP_B_RS2,
  OP_B_IMM
} op_b_sel_e;

typedef enum logic [2:0] {
  IMM_NONE,
  IMM_I,
  IMM_S,
  IMM_B,
  IMM_U,
  IMM_J,
  IMM_Z
} imm_type_e;

typedef enum logic [3:0] {
  BR_NONE,
  BR_JAL,
  BR_JALR,
  BR_BEQ,
  BR_BNE,
  BR_BLT,
  BR_BGE,
  BR_BLTU,
  BR_BGEU
} branch_op_e;

typedef enum logic [1:0] {
  MEM_NONE,
  MEM_LOAD,
  MEM_STORE
} mem_cmd_e;

typedef enum logic [1:0] {
  MEM_SIZE_BYTE,
  MEM_SIZE_HALF,
  MEM_SIZE_WORD
} mem_size_e;

typedef enum logic [1:0] {
  WB_NONE,
  WB_ALU,
  WB_MEM,
  WB_PC4
} wb_sel_e;

`endif
