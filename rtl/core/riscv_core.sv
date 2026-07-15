// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module riscv_core #(
  parameter int unsigned FetchOutstandingDepth = 1,
  parameter int unsigned IfIdQueueDepth = 2,
  parameter int unsigned MemOutstandingDepth = 1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic [31:0] boot_pc_i,

  output logic imem_req_valid_o,
  input logic imem_req_ready_i,
  output logic [31:0] imem_req_addr_o,
  output logic [31:0] imem_req_wdata_o,
  output logic [3:0] imem_req_wstrb_o,
  input logic imem_rsp_valid_i,
  output logic imem_rsp_ready_o,
  input logic [31:0] imem_rsp_rdata_i,
  input logic imem_rsp_error_i,

  output logic dmem_req_valid_o,
  input logic dmem_req_ready_i,
  output logic [31:0] dmem_req_addr_o,
  output logic [31:0] dmem_req_wdata_o,
  output logic [3:0] dmem_req_wstrb_o,
  input logic dmem_rsp_valid_i,
  output logic dmem_rsp_ready_o,
  input logic [31:0] dmem_rsp_rdata_i,
  input logic dmem_rsp_error_i,

  output logic debug_retire_valid_o,
  output logic [31:0] debug_retire_pc_o,
  output logic [31:0] debug_retire_instr_o,
  output logic debug_retire_redirect_valid_o,
  output logic [31:0] debug_retire_redirect_target_o,
  output logic debug_retire_mem_valid_o,
  output logic debug_retire_mem_write_o,
  output logic [1:0] debug_retire_mem_size_o,
  output logic [31:0] debug_retire_mem_addr_o,
  output logic [31:0] debug_retire_mem_wdata_o,
  output logic debug_retire_gpr_we_o,
  output logic [4:0] debug_retire_gpr_waddr_o,
  output logic [31:0] debug_retire_gpr_wdata_o,
  output logic debug_retire_trap_o,
  output logic debug_retire_intr_o,
  output logic [31:0] debug_retire_cause_o,
  output logic [31:0] debug_retire_tval_o,
  // 与退休 trace 同周期输出本条 WB 事务提交后的架构 CSR 快照。
  output logic [31:0] debug_retire_mstatus_o,
  output logic [31:0] debug_retire_mtvec_o,
  output logic [31:0] debug_retire_mepc_o,
  output logic [31:0] debug_retire_mcause_o,
  output logic [31:0] debug_retire_mtval_o
);

  core_bus_req_t imem_req;
  core_bus_resp_t imem_resp;
  core_bus_req_t dmem_req;
  core_bus_resp_t dmem_resp;
  core_debug_bus_t core_debug;

  assign imem_req_valid_o = imem_req.req_valid;
  assign imem_req_addr_o = imem_req.req.addr;
  assign imem_req_wdata_o = imem_req.req.wdata;
  assign imem_req_wstrb_o = imem_req.req.wstrb;
  assign imem_rsp_ready_o = imem_req.rsp_ready;
  assign imem_resp.req_ready = imem_req_ready_i;
  assign imem_resp.rsp_valid = imem_rsp_valid_i;
  assign imem_resp.rsp.rdata = imem_rsp_rdata_i;
  assign imem_resp.rsp.error = imem_rsp_error_i;

  assign dmem_req_valid_o = dmem_req.req_valid;
  assign dmem_req_addr_o = dmem_req.req.addr;
  assign dmem_req_wdata_o = dmem_req.req.wdata;
  assign dmem_req_wstrb_o = dmem_req.req.wstrb;
  assign dmem_rsp_ready_o = dmem_req.rsp_ready;
  assign dmem_resp.req_ready = dmem_req_ready_i;
  assign dmem_resp.rsp_valid = dmem_rsp_valid_i;
  assign dmem_resp.rsp.rdata = dmem_rsp_rdata_i;
  assign dmem_resp.rsp.error = dmem_rsp_error_i;

  assign debug_retire_valid_o = core_debug.valid;
  assign debug_retire_pc_o = core_debug.pc;
  assign debug_retire_instr_o = core_debug.instr;
  assign debug_retire_redirect_valid_o = core_debug.redirect_valid;
  assign debug_retire_redirect_target_o = core_debug.redirect_target_pc;
  assign debug_retire_mem_valid_o = core_debug.mem_valid;
  assign debug_retire_mem_write_o = core_debug.mem_write;
  assign debug_retire_mem_size_o = core_debug.mem_size;
  assign debug_retire_mem_addr_o = core_debug.mem_addr;
  assign debug_retire_mem_wdata_o = core_debug.mem_wdata;
  assign debug_retire_gpr_we_o = core_debug.gpr_we;
  assign debug_retire_gpr_waddr_o = core_debug.gpr_waddr;
  assign debug_retire_gpr_wdata_o = core_debug.gpr_wdata;
  assign debug_retire_trap_o = core_debug.trap;
  assign debug_retire_intr_o = core_debug.intr;
  assign debug_retire_cause_o = core_debug.cause;
  assign debug_retire_tval_o = core_debug.tval;
  assign debug_retire_mstatus_o = core_debug.csr.mstatus;
  assign debug_retire_mtvec_o = core_debug.csr.mtvec;
  assign debug_retire_mepc_o = core_debug.csr.mepc;
  assign debug_retire_mcause_o = core_debug.csr.mcause;
  assign debug_retire_mtval_o = core_debug.csr.mtval;

  riscv_core_impl #(
    .FetchOutstandingDepth(FetchOutstandingDepth),
    .IfIdQueueDepth(IfIdQueueDepth),
    .MemOutstandingDepth(MemOutstandingDepth)
  ) u_impl (
    .clk_i,
    .rst_ni,
    .boot_pc_i,
    .imem_req_o(imem_req),
    .imem_resp_i(imem_resp),
    .dmem_req_o(dmem_req),
    .dmem_resp_i(dmem_resp),
    .core_debug_o(core_debug)
  );

endmodule
