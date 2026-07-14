// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef TRANSACTION_BUS_TYPES_SVH
`define TRANSACTION_BUS_TYPES_SVH

`include "riscv_core_config.svh"
`include "riscv_isa_config.svh"

// 可复用于阶段边界的事务级子总线。valid/ready 一般属于模块或 FIFO
// 控制；只有“请求是否存在”本身有语义的 payload 才内含 valid。
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
  branch_op_e branch_op;
  mem_cmd_e mem_cmd;
  mem_size_e mem_size;
  logic mem_sign_ext;
  wb_sel_e wb_sel;
  logic rd_write;
  logic illegal_instr;
  csr_cmd_e csr_cmd;
  logic csr_use_imm;
  csr_addr_t csr_addr;
  system_op_e system_op;
  logic serialize;
} decode_ctrl_bus_t;

typedef struct packed {
  logic valid;
  logic is_interrupt;
  exception_cause_e cause;
  word_t tval;
} exception_bus_t;

typedef struct packed {
  logic valid;
  logic write;
  mem_size_e size;
  logic sign_ext;
  word_t addr;
  // store 的原始 rs2 数据；MEM 根据 addr[1:0] 和 size 生成 CoreBus lane
  // 对齐后的 wdata/wstrb，避免把移位逻辑放在 EX 关键路径上。
  word_t wdata;
} mem_req_bus_t;

typedef struct packed {
  logic valid;
  logic error;
  word_t rdata;
} mem_rsp_bus_t;

typedef struct packed {
  // valid 表示该事务会写 rd；data_valid 表示本周期 wdata 已可用于前递。
  logic valid;
  logic data_valid;
  reg_addr_t rd_addr;
  word_t wdata;
} wb_req_bus_t;

typedef struct packed {
  // valid 只在 WB fire 且本条指令没有被 trap/MRET 覆盖时成立。
  logic valid;
  csr_addr_t addr;
  word_t wdata;
} csr_write_bus_t;

// CSR 组合读端口的返回值。请求端只有一个地址字段，保持独立端口更直观；
// 返回端的合法性和数据必须同周期一起使用，因此组成单向结构体。
typedef struct packed {
  logic valid;
  word_t data;
} csr_read_rsp_bus_t;

// 当前实现的全部 M-mode CSR 架构状态。该结构同时用于 csr_unit 状态输出和
// 退休后快照，避免五个始终同生命周期的字宽信号在层次间展开。
typedef struct packed {
  word_t mstatus;
  word_t mtvec;
  word_t mepc;
  word_t mcause;
  word_t mtval;
} csr_state_bus_t;

// 从 EX 携带到 WB 的提交控制。CSR 旧值已独立进入 wb_req，避免提交端重算。
typedef struct packed {
  logic serialize;
  system_op_e system_op;
  csr_write_bus_t csr_write;
} commit_ctrl_bus_t;

// 分支 redirect 只冲刷前端；trap/MRET redirect 由 WB 同时产生 pipeline_kill，
// 清除全部年轻后端事务。顶层集中仲裁时始终令 WB 来源优先。
typedef enum logic [2:0] {
  REDIR_NONE,
  REDIR_BRANCH,
  REDIR_JAL,
  REDIR_JALR,
  REDIR_TRAP,
  REDIR_MRET
} redirect_reason_e;

typedef struct packed {
  logic valid;
  pc_t target_pc;
  redirect_reason_e reason;
} redirect_bus_t;

// 顶层统一分发的流水控制。branch redirect 的 kill=0，只刷新前端；
// WB trap/MRET 的 kill=1，同时清除所有年轻后端事务。
typedef struct packed {
  redirect_bus_t redirect;
  logic kill;
} pipeline_control_bus_t;

`endif
