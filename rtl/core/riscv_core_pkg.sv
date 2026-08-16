// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// RV32I/Zicsr 指令字段、执行操作、异常原因及核心公共类型。
// 流水、调试和性能 payload 类型也由本 package 统一拥有。
package riscv_core_pkg;

  ////////////////////////
  // 基础宽度与标量类型 //
  ////////////////////////

  // 当前实现面向 RV32I：指令固定为 32 位，整数寄存器地址固定为 5 位。
  parameter int unsigned ILen = 32;
  parameter int unsigned RegAddrW = 5;

  localparam logic [RegAddrW-1:0] ZeroReg = '0;

  typedef logic [ILen-1:0] instr_t;
  typedef logic [riscv_common_pkg::XLen-1:0] pc_t;
  typedef logic [RegAddrW-1:0] reg_addr_t;

  ////////////////////////
  // 指令编码与执行操作 //
  ////////////////////////

  // 核心内部的访存操作宽度。编码等于 log2(访问字节数)，但它描述的是 RISC-V
  // load/store 执行语义，不与 CoreBus size 字段共享类型所有权。
  typedef enum logic [1:0] {
    MEM_SIZE_BYTE = 2'd0,
    MEM_SIZE_HALF = 2'd1,
    MEM_SIZE_WORD = 2'd2
  } mem_size_e;

  // 这里只枚举 decoder 需要直接识别的 RV32I opcode。funct3/funct7 的具体组合由
  // decoder 按指令类别解释，不在 package 中复制完整指令编码表。
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

  // decoder 输出的归一化执行语义。后级只解释这些操作枚举，不再重复解析原始指令位。
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

  // ALU 两个输入端的来源选择。
  typedef enum logic {
    OP_A_RS1,
    OP_A_PC
  } op_a_sel_e;

  typedef enum logic {
    OP_B_RS2,
    OP_B_IMM
  } op_b_sel_e;

  // 立即数格式；IMM_Z 用于 CSR 指令的零扩展五位立即数。
  typedef enum logic [2:0] {
    IMM_NONE,
    IMM_I,
    IMM_S,
    IMM_B,
    IMM_U,
    IMM_J,
    IMM_Z
  } imm_type_e;

  // 控制流操作已经包含无跳转状态，便于后级统一生成 redirect。
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

  // 处理器访存方向。具体访问宽度使用 core 私有的 mem_size_e 表示。
  typedef enum logic [1:0] {
    MEM_NONE,
    MEM_LOAD,
    MEM_STORE
  } mem_cmd_e;

  // GPR 写回数据来源；WB_NONE 同时表示本指令不产生普通寄存器写回。
  typedef enum logic [2:0] {
    WB_NONE,
    WB_ALU,
    WB_MEM,
    WB_PC4,
    WB_CSR
  } wb_sel_e;

  ////////////////////////
  // CSR、SYSTEM 与异常 //
  ////////////////////////

  typedef logic [11:0] csr_addr_t;

  // Zicsr 的三种读改写语义，立即数/寄存器操作数由 csr_use_imm 单独区分。
  typedef enum logic [1:0] {
    CSR_NONE,
    CSR_RW,
    CSR_RS,
    CSR_RC
  } csr_cmd_e;

  // SYSTEM 操作随指令送至 WB；ECALL/EBREAK 在前级转为异常，MRET 在 WB 提交。
  typedef enum logic [1:0] {
    SYS_NONE,
    SYS_ECALL,
    SYS_EBREAK,
    SYS_MRET
  } system_op_e;

  // 当前核心支持的同步异常 cause，编码与 RISC-V mcause 的低位定义一致。
  typedef enum logic [3:0] {
    EXC_INST_ADDR_MISALIGNED = 4'd0,
    EXC_INST_ACCESS_FAULT = 4'd1,
    EXC_ILLEGAL_INSTR = 4'd2,
    EXC_BREAKPOINT = 4'd3,
    EXC_LOAD_ADDR_MISALIGNED = 4'd4,
    EXC_LOAD_ACCESS_FAULT = 4'd5,
    EXC_STORE_ADDR_MISALIGNED = 4'd6,
    EXC_STORE_ACCESS_FAULT = 4'd7,
    EXC_ECALL_M = 4'd11
  } exception_cause_e;

  // 已实现的 M-mode CSR 地址；只读机器标识寄存器也由 csr_unit 统一解码。
  localparam csr_addr_t CsrMstatus = 12'h300;
  localparam csr_addr_t CsrMtvec = 12'h305;
  localparam csr_addr_t CsrMepc = 12'h341;
  localparam csr_addr_t CsrMcause = 12'h342;
  localparam csr_addr_t CsrMtval = 12'h343;
  localparam csr_addr_t CsrMvendorid = 12'hf11;
  localparam csr_addr_t CsrMarchid = 12'hf12;

  // 调试接口中的退休访存事件编码；相关调试 payload 类型同样由本 package 定义。
  typedef enum logic [1:0] {
    RETIRE_MEM_NONE = 2'd0,
    RETIRE_MEM_READ = 2'd1,
    RETIRE_MEM_WRITE = 2'd2
  } retire_mem_op_e;

  ////////////////////////////////
  // 执行与提交子事务 payload 类型 //
  ////////////////////////////////

  // 译码得到的寄存器地址，独立于寄存器值保存，便于后级执行相关性比较。
  typedef struct packed {
    reg_addr_t rs1_addr;
    reg_addr_t rs2_addr;
    reg_addr_t rd_addr;
  } reg_addr_payload_t;

  // EX 所需的两路寄存器快照和已扩展立即数。
  typedef struct packed {
    riscv_common_pkg::word_t rs1_value;
    riscv_common_pkg::word_t rs2_value;
    riscv_common_pkg::word_t imm;
  } exec_data_payload_t;

  // decoder 产生的完整执行控制，字段均描述归一化语义而非原始指令编码。
  typedef struct packed {
    alu_op_e alu_op;
    op_a_sel_e op_a_sel;
    op_b_sel_e op_b_sel;
    branch_op_e branch_op;
    mem_cmd_e mem_cmd;
    mem_size_e mem_size;
    logic mem_sign_ext;
    wb_sel_e wb_sel;
    logic rd_write;
    csr_cmd_e csr_cmd;
    logic csr_use_imm;
    csr_addr_t csr_addr;
    system_op_e system_op;
    logic serialize;
  } execute_ctrl_payload_t;

  // decoder 的组合结果；字段布局直接复用 ID/EX payload 的子结构，避免在 ID
  // 中把扁平接口字段重新拼装为 reg_addr 和 ctrl。
  typedef struct packed {
    reg_addr_payload_t reg_addr;
    imm_type_e imm_type;
    execute_ctrl_payload_t ctrl;
    logic illegal;
  } decode_result_t;

  // 随指令传播的精确异常；一旦 valid 置位，年轻流水级只能保留而不能覆盖。
  typedef struct packed {
    logic valid;
    logic is_interrupt;
    exception_cause_e cause;
    riscv_common_pkg::word_t tval;
  } exception_payload_t;

  // EX 生成、MEM 消费的架构访存请求。wdata 在此仍未按总线 lane 对齐。
  typedef struct packed {
    logic valid;
    logic write;
    mem_size_e size;
    logic sign_ext;
    riscv_common_pkg::word_t addr;
    riscv_common_pkg::word_t wdata;
  } mem_req_payload_t;

  // 通用 GPR 写回候选；data_valid 将“存在生产者”和“结果已就绪”明确分开。
  typedef struct packed {
    logic valid;
    logic data_valid;
    reg_addr_t rd_addr;
    riscv_common_pkg::word_t wdata;
  } writeback_payload_t;

  // 在 WB 提交的 CSR 写请求，不允许在更年轻流水级提前修改架构状态。
  typedef struct packed {
    logic valid;
    csr_addr_t addr;
    riscv_common_pkg::word_t wdata;
  } csr_write_payload_t;

  // 已实现 M-mode CSR 的架构快照，供退休调试记录本条指令提交后的状态。
  typedef struct packed {
    riscv_common_pkg::word_t mstatus;
    riscv_common_pkg::word_t mtvec;
    riscv_common_pkg::word_t mepc;
    riscv_common_pkg::word_t mcause;
    riscv_common_pkg::word_t mtval;
  } csr_state_payload_t;

  // 随指令送往 WB 的串行化和 SYSTEM/CSR 提交控制。
  typedef struct packed {
    logic serialize;
    system_op_e system_op;
    csr_write_payload_t csr_write;
  } commit_ctrl_payload_t;

  //////////////////////////////////
  // 提交、调试与性能观测 payload 类型 //
  //////////////////////////////////

  // 指令的不可变元数据。它是流水线事务的唯一 PC/指令来源，避免外层字段和
  // debug 字段重复携带相同信息。
  typedef struct packed {
    pc_t pc;
    instr_t instr;
    logic [63:0] instid;
  } instruction_meta_payload_t;

  // MEM 完成后仍需送达退休观察端的访存结果。功能 mem_req 仍独立保留 sign_ext
  // 和原始 store 数据，避免调试语义反向约束执行请求。
  typedef struct packed {
    retire_mem_op_e mem_op;
    mem_size_e mem_size;
    riscv_common_pkg::word_t mem_addr;
    riscv_common_pkg::word_t mem_data;
  } retire_mem_payload_t;

  typedef struct packed {
    logic valid;
    pc_t target_pc;
  } retire_redirect_payload_t;

  // 尚未返回的 load 目标寄存器；valid 属于该组合旁路事件，不重复放入 payload。
  typedef struct packed {reg_addr_t rd_addr;} mem_pending_payload_t;

  // WB 到 CSR 单元的完整架构状态更新请求。
  typedef struct packed {
    csr_write_payload_t write;
    logic trap;
    riscv_common_pkg::word_t trap_epc;
    logic trap_is_interrupt;
    exception_cause_e trap_cause;
    riscv_common_pkg::word_t trap_tval;
    logic mret;
  } csr_commit_payload_t;

  // EX/MEM 与 MEM/WB 之间的公共提交上下文。MEM 只在 outstanding 完成时修改
  // retire_mem.mem_data，其余字段直接整体转移。
  typedef struct packed {
    instruction_meta_payload_t meta;
    writeback_payload_t wb_req;
    exception_payload_t exception;
    commit_ctrl_payload_t commit;
    retire_mem_payload_t retire_mem;
    retire_redirect_payload_t redirect;
  } commit_context_payload_t;

  // 完整退休快照只在 WB 生成，CSR 快照和 GPR 写回字段不再随流水线传播。
  typedef struct packed {
    instruction_meta_payload_t meta;
    logic gpr_we;
    reg_addr_t gpr_waddr;
    riscv_common_pkg::word_t gpr_wdata;
    retire_mem_payload_t mem;
    retire_redirect_payload_t redirect;
    csr_state_payload_t csr;
  } retire_debug_payload_t;

  // 性能统计快照；边界传输、边界阻塞和局部阻塞计数具有互不相同的解释口径。
  typedef struct packed {
    logic [63:0] cycle_count;
    logic [63:0] instret_count;
    logic [63:0] if_id_fire_count;
    logic [63:0] id_ex_fire_count;
    logic [63:0] ex_mem_fire_count;
    logic [63:0] mem_wb_fire_count;
    logic [63:0] if_id_stall_cycle_count;
    logic [63:0] id_ex_stall_cycle_count;
    logic [63:0] ex_mem_stall_cycle_count;
    logic [63:0] mem_wb_stall_cycle_count;
    logic [63:0] if_starve_cycle_count;
    logic [63:0] id_local_stall_cycle_count;
    logic [63:0] ex_local_stall_cycle_count;
    logic [63:0] mem_local_stall_cycle_count;
    logic [63:0] wb_local_stall_cycle_count;
  } performance_debug_payload_t;

  ////////////////////
  // 流水级边界事务 //
  ////////////////////

  // 四个流水级边界的事务类型；越靠后只保留仍可能影响提交的功能字段。
  typedef struct packed {
    instruction_meta_payload_t meta;
    exception_payload_t exception;
  } if_id_payload_t;

  typedef struct packed {
    instruction_meta_payload_t meta;
    reg_addr_payload_t reg_addr;
    exec_data_payload_t exec_data;
    execute_ctrl_payload_t ctrl;
    exception_payload_t exception;
  } id_ex_payload_t;

  typedef struct packed {
    // "context" is a SystemVerilog keyword in the target toolchain; keep the
    // same semantic boundary under a tool-safe field name.
    commit_context_payload_t commit_ctx;
    mem_req_payload_t mem_req;
  } ex_mem_payload_t;

  typedef commit_context_payload_t mem_wb_payload_t;

endpackage
