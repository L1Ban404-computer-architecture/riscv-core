// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

package riscv_core_pkg;

  // 本 package 只拥有 core 内部的 ISA、事务、流水线和调试类型。声明所需的数据字
  // 与访问宽度来自最底层 common package，不依赖任何 CoreBus 或 AXI4 协议类型。
  // 当前实现面向 RV32I：指令固定为 32 位，整数寄存器地址固定为 5 位。
  parameter int unsigned ILen = 32;
  parameter int unsigned RegAddrW = 5;

  localparam logic [RegAddrW-1:0] ZeroReg = '0;

  typedef logic [ILen-1:0] instr_t;
  typedef logic [riscv_common_pkg::XLen-1:0] pc_t;
  typedef logic [RegAddrW-1:0] reg_addr_t;

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
    EXC_INST_ADDR_MISALIGNED  = 4'd0,
    EXC_INST_ACCESS_FAULT     = 4'd1,
    EXC_ILLEGAL_INSTR         = 4'd2,
    EXC_BREAKPOINT            = 4'd3,
    EXC_LOAD_ADDR_MISALIGNED  = 4'd4,
    EXC_LOAD_ACCESS_FAULT     = 4'd5,
    EXC_STORE_ADDR_MISALIGNED = 4'd6,
    EXC_STORE_ACCESS_FAULT    = 4'd7,
    EXC_ECALL_M               = 4'd11
  } exception_cause_e;

  // 已实现的 M-mode CSR 地址；只读机器标识寄存器也由 csr_unit 统一解码。
  localparam csr_addr_t CsrMstatus = 12'h300;
  localparam csr_addr_t CsrMtvec = 12'h305;
  localparam csr_addr_t CsrMepc = 12'h341;
  localparam csr_addr_t CsrMcause = 12'h342;
  localparam csr_addr_t CsrMtval = 12'h343;
  localparam csr_addr_t CsrMvendorid = 12'hf11;
  localparam csr_addr_t CsrMarchid = 12'hf12;

  // 以下结构是可复用于流水级边界的事务子 payload。ready/valid 一般属于承载这些
  // payload 的模块或 FIFO；只有“请求是否存在”本身具有指令语义时才把 valid 放入结构。
  typedef struct packed {
    reg_addr_t rs1_addr;
    reg_addr_t rs2_addr;
    reg_addr_t rd_addr;
  } reg_addr_bus_t;

  typedef struct packed {
    riscv_common_pkg::word_t rs1_value;
    riscv_common_pkg::word_t rs2_value;
    riscv_common_pkg::word_t imm;
  } exec_data_bus_t;

  // decoder 单独报告非法指令；合法指令的全部执行控制直接进入 ID/EX，避免维护一份
  // 仅相差 illegal 字段的重复控制结构。serialize 表示该指令必须等待更老事务排空。
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
  } execute_ctrl_bus_t;

  // 异常一旦有效便随所属指令流动。is_interrupt 为未来中断入口保留；tval 保存异常
  // 相关地址或指令值，普通流水副作用必须在 valid 时受到抑制。
  typedef struct packed {
    logic valid;
    logic is_interrupt;
    exception_cause_e cause;
    riscv_common_pkg::word_t tval;
  } exception_bus_t;

  // EX 生成的功能访存请求。wdata 保存未经 lane 移位的原始 rs2 数据，MEM 根据
  // addr[1:0] 和 size 形成 CoreBus 对齐后的 wdata/wstrb，避免加长 EX 关键路径。
  typedef struct packed {
    logic valid;
    logic write;
    mem_size_e size;
    logic sign_ext;
    riscv_common_pkg::word_t addr;
    riscv_common_pkg::word_t wdata;
  } mem_req_bus_t;

  // valid 表示该事务会写 rd；data_valid 表示 wdata 已在本周期可用于前递。
  // load 等延迟结果可以先声明写回目的寄存器，再在数据返回后置位 data_valid。
  typedef struct packed {
    logic valid;
    logic data_valid;
    reg_addr_t rd_addr;
    riscv_common_pkg::word_t wdata;
  } wb_req_bus_t;

  // CSR 写事务只允许在 WB fire 且未被 trap/MRET 覆盖时提交。
  typedef struct packed {
    logic valid;
    csr_addr_t addr;
    riscv_common_pkg::word_t wdata;
  } csr_write_bus_t;

  // CSR 组合读端口的返回值；合法性与数据必须在同一周期一起使用。
  typedef struct packed {
    logic valid;
    riscv_common_pkg::word_t data;
  } csr_read_rsp_bus_t;

  // 当前实现的全部可变 M-mode CSR 状态，同时用于 csr_unit 输出与退休调试快照。
  typedef struct packed {
    riscv_common_pkg::word_t mstatus;
    riscv_common_pkg::word_t mtvec;
    riscv_common_pkg::word_t mepc;
    riscv_common_pkg::word_t mcause;
    riscv_common_pkg::word_t mtval;
  } csr_state_bus_t;

  // 从 EX 携带到 WB 的提交控制。CSR 旧值已独立进入 wb_req，提交端无需重新计算。
  typedef struct packed {
    logic serialize;
    system_op_e system_op;
    csr_write_bus_t csr_write;
  } commit_ctrl_bus_t;

  // redirect.valid 为单周期控制事件，target_pc 是下一条应取指的功能地址。
  typedef struct packed {
    logic valid;
    pc_t target_pc;
  } redirect_bus_t;

  // 顶层统一分发的流水控制：任何 redirect 都刷新前端；只有 WB 的 trap/MRET
  // 额外置位 flush_backend，清除所有更年轻的后端事务。
  typedef struct packed {
    redirect_bus_t redirect;
    logic flush_backend;
  } pipeline_control_bus_t;

  // 调试 payload 只描述对外可观察事件，不得被功能控制、异常提交或存储事务反向读取。
  typedef enum logic [1:0] {
    RETIRE_MEM_NONE = 2'd0,
    RETIRE_MEM_READ = 2'd1,
    RETIRE_MEM_WRITE = 2'd2
  } retire_mem_op_e;

  // 随指令贯穿流水线的退休记录。instid 在取指请求握手时分配；真正对外有效的时刻
  // 由独立退休脉冲给出。异常指令仍可退休，但普通 GPR/访存副作用必须被清零。
  typedef struct packed {
    pc_t pc;
    instr_t instr;
    logic [63:0] instid;
    logic gpr_we;
    reg_addr_t gpr_waddr;
    riscv_common_pkg::word_t gpr_wdata;
    retire_mem_op_e mem_op;
    mem_size_e mem_size;
    riscv_common_pkg::word_t mem_addr;
    riscv_common_pkg::word_t mem_data;
    logic redirect_valid;
    pc_t redirect_target_pc;
    csr_state_bus_t csr;
  } core_retire_debug_bus_t;

  // 实时性能计数器不属于公开 runner ABI。上层 RTL model 可在退出前采样；后续扩展
  // 计数项只影响这条私有调试通路，不应进入功能流水控制。
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
  } core_performance_debug_bus_t;

  // 以下结构是弹性流水级之间随指令移动的完整 payload。exception 保持上游优先，
  // 后级只能补充尚未出现的异常；级间寄存器/FIFO 和 ready/valid 不包含在结构内。
  typedef struct packed {
    pc_t pc;
    instr_t instr;
    exception_bus_t exception;
    core_retire_debug_bus_t debug;
  } if_id_bus_t;

  typedef struct packed {
    pc_t pc;
    instr_t instr;
    reg_addr_bus_t reg_addr;
    exec_data_bus_t exec_data;
    execute_ctrl_bus_t ctrl;
    exception_bus_t exception;
    core_retire_debug_bus_t debug;
  } id_ex_bus_t;

  // 精确异常提交需要功能 PC，因此 EX/MEM 独立携带 pc，不从 debug payload 反向获取。
  typedef struct packed {
    pc_t pc;
    mem_req_bus_t mem_req;
    wb_req_bus_t wb_req;
    exception_bus_t exception;
    commit_ctrl_bus_t commit;
    core_retire_debug_bus_t debug;
  } ex_mem_bus_t;

  // MEM/WB 已完成访存，故不再携带 mem_req；剩余字段足以完成 GPR/CSR、trap/MRET
  // 的唯一架构提交，并生成最终退休记录。
  typedef struct packed {
    pc_t pc;
    wb_req_bus_t wb_req;
    exception_bus_t exception;
    commit_ctrl_bus_t commit;
    core_retire_debug_bus_t debug;
  } mem_wb_bus_t;

endpackage
