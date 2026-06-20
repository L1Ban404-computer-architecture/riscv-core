// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef TRANSACTION_BUS_TYPES_SVH
`define TRANSACTION_BUS_TYPES_SVH

`include "riscv_core_config.svh"
`include "riscv_isa_config.svh"

// AXI4-Lite 边界类型。master 输出 req，slave 返回 resp。
typedef logic [2:0] axi_lite_prot_t;

typedef enum logic [1:0] {
  AXI_RESP_OKAY = 2'b00,
  AXI_RESP_EXOKAY = 2'b01,
  AXI_RESP_SLVERR = 2'b10,
  AXI_RESP_DECERR = 2'b11
} axi_lite_resp_e;

typedef struct packed {
  word_t addr;
  axi_lite_prot_t prot;
} axi_lite_aw_chan_t;

typedef struct packed {
  word_t data;
  byte_en_t strb;
} axi_lite_w_chan_t;

typedef struct packed {axi_lite_resp_e resp;} axi_lite_b_chan_t;

typedef struct packed {
  word_t addr;
  axi_lite_prot_t prot;
} axi_lite_ar_chan_t;

typedef struct packed {
  word_t data;
  axi_lite_resp_e resp;
} axi_lite_r_chan_t;

typedef struct packed {
  axi_lite_aw_chan_t aw;
  logic aw_valid;
  axi_lite_w_chan_t w;
  logic w_valid;
  logic b_ready;
  axi_lite_ar_chan_t ar;
  logic ar_valid;
  logic r_ready;
} axi_lite_req_t;

typedef struct packed {
  logic aw_ready;
  logic w_ready;
  axi_lite_b_chan_t b;
  logic b_valid;
  logic ar_ready;
  axi_lite_r_chan_t r;
  logic r_valid;
} axi_lite_resp_t;

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
  logic valid;
  logic data_valid;
  reg_addr_t rd_addr;
  word_t wdata;
} wb_req_bus_t;

`endif
