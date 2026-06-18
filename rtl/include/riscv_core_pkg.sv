// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

package riscv_core_pkg;

  // ---------------------------------------------------------------------------
  // 基础参数与常用类型
  // ---------------------------------------------------------------------------
  //
  // 当前核心以 RV32I 作为第一阶段目标，因此 XLen/ILen 先固定为 32。
  // 后续如果扩展到 RV64，可以优先从这些 typedef 和参数开始收敛修改面。
  parameter int unsigned XLen = 32;
  parameter int unsigned ILen = 32;
  parameter int unsigned RegAddrW = 5;
  parameter int unsigned ByteW = 8;
  parameter int unsigned StrbW = XLen / ByteW;

  localparam logic [RegAddrW-1:0] ZeroReg = '0;

  typedef logic [XLen-1:0] word_t;
  typedef logic [ILen-1:0] instr_t;
  typedef logic [XLen-1:0] pc_t;
  typedef logic [RegAddrW-1:0] reg_addr_t;
  typedef logic [StrbW-1:0] byte_en_t;

  // ---------------------------------------------------------------------------
  // RV32I 指令编码基础类型
  // ---------------------------------------------------------------------------
  //
  // opcode/funct3/funct7 仍然保留为显式类型，decoder 可以直接使用这些
  // 编码产生控制总线。这里不把所有 funct3/funct7 组合都枚举出来，避免
  // 在包里提前固化过多 decoder 局部细节。
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

  // ---------------------------------------------------------------------------
  // 译码控制枚举
  // ---------------------------------------------------------------------------

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
    ALU_PASS_A,
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

  typedef enum logic [2:0] {
    WB_NONE,
    WB_ALU,
    WB_MEM,
    WB_PC4,
    WB_IMM
  } wb_sel_e;

  typedef enum logic [2:0] {
    REDIR_NONE,
    REDIR_BRANCH,
    REDIR_JAL,
    REDIR_JALR,
    REDIR_TRAP,
    REDIR_MRET
  } redirect_reason_e;

  // ---------------------------------------------------------------------------
  // 事务级子总线
  // ---------------------------------------------------------------------------
  //
  // 设计原则：
  // - 阶段间结构级总线优先复用这些子事务，而不是直接堆字段。
  // - valid/ready 一般属于模块接口或 FIFO 控制，不默认塞进每个 payload。
  // - 对“请求是否存在”本身有语义的总线，例如 mem_req/wb_req，会保留 valid。

  typedef struct packed {
    pc_t pc;
    instr_t instr;
  } fetch_bus_t;

  typedef struct packed {
    reg_addr_t rs1_addr;
    reg_addr_t rs2_addr;
    reg_addr_t rd_addr;
  } reg_addr_bus_t;

  typedef struct packed {
    pc_t pc;
    word_t rs1_value;
    word_t rs2_value;
    word_t imm;
  } exec_data_bus_t;

  typedef struct packed {
    alu_op_e alu_op;
    op_a_sel_e op_a_sel;
    op_b_sel_e op_b_sel;
    imm_type_e imm_type;
    branch_op_e branch_op;
    mem_cmd_e mem_cmd;
    mem_size_e mem_size;
    logic mem_sign_ext;
    wb_sel_e wb_sel;
    logic rd_write;
    logic illegal_instr;
  } decode_ctrl_bus_t;

  typedef struct packed {
    logic valid;
    logic write;
    mem_size_e size;
    logic sign_ext;
    word_t addr;
    word_t wdata;
    byte_en_t byte_en;
  } mem_req_bus_t;

  typedef struct packed {
    logic valid;
    word_t rdata;
  } mem_rsp_bus_t;

  typedef struct packed {
    // valid 表示该事务会写 rd；data_valid 表示本周期 wdata 已可用于前递。
    // 对 load 来说，valid 可以很早成立，但 data_valid 要等 LSU 返回数据。
    logic valid;
    logic data_valid;
    reg_addr_t rd_addr;
    word_t wdata;
  } wb_req_bus_t;

  typedef struct packed {
    logic valid;
    pc_t target_pc;
    redirect_reason_e reason;
  } redirect_bus_t;

  // ---------------------------------------------------------------------------
  // Debug/retire 追踪总线
  // ---------------------------------------------------------------------------
  //
  // debug 总线只描述“这条指令发生了什么”，不应反向参与功能控制。
  // 后续仿真环境可以观察 wb_debug_bus_t.valid：当它为 1 时，表示一条指令
  // 在架构层面退休。这个结构也为后续接 RVFI 留出自然映射位置。

  typedef struct packed {
    // IF debug 只记录原始取指事务，后续阶段在此基础上逐步补充行为。
    fetch_bus_t fetch;
  } if_debug_bus_t;

  typedef struct packed {
    if_debug_bus_t if_debug;
    reg_addr_bus_t reg_addr;
    decode_ctrl_bus_t ctrl;
  } id_debug_bus_t;

  typedef struct packed {
    id_debug_bus_t id_debug;
    logic redirect_taken;
    pc_t redirect_target_pc;
    word_t alu_result;
  } ex_debug_bus_t;

  typedef struct packed {
    ex_debug_bus_t ex_debug;
    mem_req_bus_t mem_req;
    mem_rsp_bus_t mem_rsp;
  } mem_debug_bus_t;

  typedef struct packed {
    logic valid;
    mem_debug_bus_t mem_debug;
    wb_req_bus_t wb_req;
  } wb_debug_bus_t;

  typedef struct packed {
    // core_debug_bus_t 面向上层仿真环境，语义等价于展开后的 wb_debug_bus_t。
    // valid 为 1 表示一条指令退休，其余字段直接描述这条指令的完整行为。
    logic valid;
    fetch_bus_t fetch;
    reg_addr_bus_t reg_addr;
    decode_ctrl_bus_t ctrl;
    logic redirect_taken;
    pc_t redirect_target_pc;
    word_t alu_result;
    mem_req_bus_t mem_req;
    mem_rsp_bus_t mem_rsp;
    wb_req_bus_t wb_req;
  } core_debug_bus_t;

  // ---------------------------------------------------------------------------
  // 阶段间结构级事务
  // ---------------------------------------------------------------------------
  //
  // 这些类型描述 stage 边界处“随指令一起移动”的 payload。
  // 具体寄存器墙/FIFO 由各 stage 内部维护，顶层只连接事务接口。
  // 约束：已经进入 EX 及后续阶段的事务不再被 redirect 冲刷；redirect 只
  // 影响更年轻的前端事务。

  typedef struct packed {
    fetch_bus_t fetch;
    if_debug_bus_t debug;
  } if_id_bus_t;

  typedef struct packed {
    fetch_bus_t fetch;
    reg_addr_bus_t reg_addr;
    exec_data_bus_t exec_data;
    decode_ctrl_bus_t ctrl;
    id_debug_bus_t debug;
  } id_ex_bus_t;

  typedef struct packed {
    mem_req_bus_t mem_req;
    wb_req_bus_t wb_req;
    ex_debug_bus_t debug;
  } ex_mem_bus_t;

  typedef struct packed {
    wb_req_bus_t wb_req;
    mem_debug_bus_t debug;
  } mem_wb_bus_t;

  // ---------------------------------------------------------------------------
  // 数据前递辅助类型
  // ---------------------------------------------------------------------------
  //
  // forwarding unit 读取较老指令发出的写回请求。如果 rd 匹配且 data_valid
  // 已成立，则选择该源前递；如果 rd 匹配但 data_valid 未成立，则应阻塞
  // 当前 EX 事务，等待数据可用。

  typedef enum logic [1:0] {
    FWD_NONE,
    FWD_FROM_EX,
    FWD_FROM_MEM,
    FWD_FROM_WB
  } forward_sel_e;

  typedef struct packed {
    forward_sel_e rs1_sel;
    forward_sel_e rs2_sel;
    logic stall;
  } forward_ctrl_bus_t;

  typedef struct packed {
    wb_req_bus_t ex_wb;
    wb_req_bus_t mem_wb;
    wb_req_bus_t wb_wb;
  } forward_src_bus_t;

endpackage
