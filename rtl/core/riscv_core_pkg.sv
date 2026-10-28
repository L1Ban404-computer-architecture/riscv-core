// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// RV32I/E/Zicsr/Zifencei 指令字段、执行操作、异常原因及核心公共类型。
// 功能流水事务由本 package 定义。
`ifndef RISCV_CORE_RVE
`define RISCV_CORE_RVE 1
`endif

package riscv_core_pkg;
  localparam bit Rve = `RISCV_CORE_RVE;
  localparam int unsigned GprCount = Rve ? 16 : 32;

  // 基础宽度与标量类型

  // 当前实现的数据与地址宽度均为 32 位，每个数据字由 4 个 8 位 byte lane 组成。
  parameter int unsigned XLen = 32;
  typedef logic [XLen-1:0] word_t;

  // RV32I/E 共用指令编码：指令固定为 32 位，整数寄存器地址固定为 5 位。
  parameter int unsigned ILen = 32;
  parameter int unsigned RegAddrW = 5;

  localparam logic [RegAddrW-1:0] ZeroReg = '0;

  typedef logic [ILen-1:0] instr_t;
  typedef logic [XLen-1:0] pc_t;
  typedef logic [RegAddrW-1:0] reg_addr_t;

  // 分支预测器配置与表项类型；CPU 直接使用这些默认值。

  typedef enum logic {
    BTB_BRANCH,
    BTB_JAL
  } btb_entry_type_e;

  parameter bit BtbEnable = 1'b0;
  parameter int unsigned BtbSetCount = 1;
  parameter int unsigned BtbWayCount = 4;

  // 指令编码与执行操作

  // 核心内部的访存操作宽度。编码等于 log2(访问字节数)，描述 RISC-V load/store
  // 执行语义，与 CoreBus 的 core_bus_size_e 相互独立。
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

  // CSR、SYSTEM 与异常

  typedef logic [11:0] csr_addr_t;

  // Zicsr 的三种读改写语义，立即数/寄存器操作数由 csr_use_imm 单独区分。
  typedef enum logic [1:0] {
    CSR_NONE,
    CSR_RW,
    CSR_RS,
    CSR_RC
  } csr_cmd_e;

  // 译码的 SYSTEM 操作；ECALL/EBREAK 在 ID 转为异常，EX 之后仅保留 is_mret。
  typedef enum logic [1:0] {
    SYS_NONE,
    SYS_ECALL,
    SYS_EBREAK,
    SYS_MRET
  } system_op_e;

  // WB 作为唯一架构提交点产出的提交类别。
  typedef enum logic [1:0] {
    COMMIT_NORMAL,
    COMMIT_TRAP,
    COMMIT_MRET
  } commit_kind_e;

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

  // 已实现的 M-mode CSR 地址；ID 将这些架构地址映射为内部编号。
  localparam csr_addr_t CsrMstatus = 12'h300;
  localparam csr_addr_t CsrMtvec = 12'h305;
  localparam csr_addr_t CsrMepc = 12'h341;
  localparam csr_addr_t CsrMcause = 12'h342;
  localparam csr_addr_t CsrMtval = 12'h343;
  localparam csr_addr_t CsrMvendorid = 12'hf11;
  localparam csr_addr_t CsrMarchid = 12'hf12;

  // 完整 CSR 地址只在 ID 检查一次；后续流水级携带紧凑编号。
  typedef enum logic [2:0] {
    CSR_IDX_INVALID,
    CSR_IDX_MSTATUS,
    CSR_IDX_MTVEC,
    CSR_IDX_MEPC,
    CSR_IDX_MCAUSE,
    CSR_IDX_MTVAL,
    CSR_IDX_MVENDORID,
    CSR_IDX_MARCHID
  } csr_index_e;

  function automatic csr_index_e csr_index(input csr_addr_t addr);
    case (addr)
      CsrMstatus: return CSR_IDX_MSTATUS;
      CsrMtvec: return CSR_IDX_MTVEC;
      CsrMepc: return CSR_IDX_MEPC;
      CsrMcause: return CSR_IDX_MCAUSE;
      CsrMtval: return CSR_IDX_MTVAL;
      CsrMvendorid: return CSR_IDX_MVENDORID;
      CsrMarchid: return CSR_IDX_MARCHID;
      default: return CSR_IDX_INVALID;
    endcase
  endfunction

  // CSR 源操作数经 commit_ctx.value 传到 WB，旧值和新值均在 WB 产生。
  typedef struct packed {
    csr_cmd_e cmd;
    csr_index_e index;
    logic write;
  } csr_op_payload_t;

  // 执行与提交子事务 payload 类型

  // 无背压事件接口的数据；有效位由对应 interface 单独携带。
  typedef struct packed {
    reg_addr_t rd_addr;
    word_t wdata;
  } gpr_write_payload_t;

  typedef struct packed {
    pc_t  target_pc;
    // 取指侧指令状态失效，可同时用于 I-cache 与分支预测器。
    logic imem_invalidate;
  } redirect_payload_t;

  // 预测器训练只接受已确认合法的类型、编码目标与立即数方向，不需要实际 taken。
  typedef struct packed {
    pc_t pc;
    branch_op_e branch_op;
    pc_t target_pc;
    logic backward;
  } branch_update_payload_t;

  // 译码得到的寄存器地址，独立于寄存器值保存，便于后级执行相关性比较。
  typedef struct packed {
    reg_addr_t rs1_addr;
    reg_addr_t rs2_addr;
    reg_addr_t rd_addr;
    logic rs1_used;
    logic rs2_used;
  } reg_addr_payload_t;

  // EX 所需的两路寄存器快照和已扩展立即数。
  typedef struct packed {
    word_t rs1_value;
    word_t rs2_value;
    word_t imm;
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
    csr_op_payload_t csr;
    logic csr_use_imm;
    system_op_e system_op;
    // FENCE.I 在 EX 等待更老事务排空后失效取指状态并重取后续指令。
    logic fence_i;
  } execute_ctrl_payload_t;

  // decoder 的组合结果；字段布局直接复用 ID/EX payload 的子结构，避免在 ID
  // 中把扁平接口字段重新拼装为 reg_addr 和 ctrl。
  typedef struct packed {
    reg_addr_payload_t reg_addr;
    imm_type_e imm_type;
    execute_ctrl_payload_t ctrl;
    logic illegal;
  } decode_result_t;

  // 随指令传播的精确异常；后续流水级不得覆盖已记录的异常。
  typedef struct packed {
    logic valid;
    exception_cause_e cause;
    word_t tval;
  } exception_payload_t;

  // 先检测出的异常优先。existing.valid 时保持原样，否则记录新异常。
  function automatic exception_payload_t raise_exception(
      input exception_payload_t existing, input exception_cause_e cause, input word_t tval);
    exception_payload_t result;
    if (existing.valid) return existing;
    result = '0;
    result.valid = 1'b1;
    result.cause = cause;
    result.tval = tval;
    return result;
  endfunction

  // EX 生成、MEM 消费的访存属性；地址在 commit_ctx.value 中。
  // wdata 保存原始 rs2，MEM 按访问宽度整理总线 lane。
  typedef struct packed {
    logic valid;
    logic write;
    mem_size_e size;
    logic sign_ext;
    word_t wdata;
  } mem_req_payload_t;

  // GPR 目的寄存器与结果就绪状态。write 标识生产者，ready 才允许前递 value。
  // Load 到 MEM、CSR 到 WB 才就绪；等待时不能绕过它们前递更老的结果。
  typedef struct packed {
    logic write;
    logic ready;
    reg_addr_t addr;
  } gpr_dest_t;

  // 已实现 M-mode CSR 的架构状态。
  typedef struct packed {
    word_t mstatus;
    word_t mtvec;
    word_t mepc;
    word_t mcause;
    word_t mtval;
  } csr_state_payload_t;

  // 随指令送往 WB 的 MRET/CSR 提交控制。
  typedef struct packed {
    logic is_mret;
    csr_op_payload_t csr;
  } commit_ctrl_payload_t;

  // 前端执行与异常检测所需的指令元数据。
  typedef struct packed {
    pc_t pc;
    instr_t instr;
    // 请求被接受时采纳的方向快照，仅随指令保留到 EX。
    logic predicted_taken;
  } instruction_meta_payload_t;

  // WB 到 CSR 单元的完整架构状态更新请求。
  typedef enum logic [1:0] {
    CSR_COMMIT_NONE,
    CSR_COMMIT_WRITE,
    CSR_COMMIT_TRAP,
    CSR_COMMIT_MRET
  } csr_commit_op_e;

  typedef struct packed {
    csr_commit_op_e op;
    csr_index_e index;
    word_t wdata;
    word_t trap_epc;
    exception_cause_e trap_cause;
    word_t trap_tval;
  } csr_commit_payload_t;

  // EX/MEM 与 MEM/WB 共用的提交上下文；退休观察字段不进入功能流水。
  // value 共用一个 XLEN 寄存器：EX 输出运算结果、访存地址或 CSR 源操作数，
  // MEM 用 load 结果替换地址，WB 用 CSR 旧值完成 GPR 写回。
  // value 是否可作为 GPR 结果由 gpr.ready 决定，不能仅检查 gpr.write。
  typedef struct packed {
    pc_t pc;
    gpr_dest_t gpr;
    word_t value;
    exception_payload_t exception;
    commit_ctrl_payload_t commit;
  } commit_context_payload_t;

  // 流水级边界事务

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
    commit_context_payload_t commit_ctx;
    mem_req_payload_t mem_req;
  } ex_mem_payload_t;

  typedef commit_context_payload_t mem_wb_payload_t;

endpackage
