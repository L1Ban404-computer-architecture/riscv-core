// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

module riscv_core_tb #(
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
  output logic [31:0] debug_retire_mstatus_o,
  output logic [31:0] debug_retire_mtvec_o,
  output logic [31:0] debug_retire_mepc_o,
  output logic [31:0] debug_retire_mcause_o,
  output logic [31:0] debug_retire_mtval_o
);

  riscv_core #(
    .FetchOutstandingDepth(FetchOutstandingDepth),
    .IfIdQueueDepth(IfIdQueueDepth),
    .MemOutstandingDepth(MemOutstandingDepth)
  ) u_dut (
    .clk_i,
    .rst_ni,
    .boot_pc_i,
    .imem_req_valid_o,
    .imem_req_ready_i,
    .imem_req_addr_o,
    .imem_req_wdata_o,
    .imem_req_wstrb_o,
    .imem_rsp_valid_i,
    .imem_rsp_ready_o,
    .imem_rsp_rdata_i,
    .imem_rsp_error_i,
    .dmem_req_valid_o,
    .dmem_req_ready_i,
    .dmem_req_addr_o,
    .dmem_req_wdata_o,
    .dmem_req_wstrb_o,
    .dmem_rsp_valid_i,
    .dmem_rsp_ready_o,
    .dmem_rsp_rdata_i,
    .dmem_rsp_error_i,
    .debug_retire_valid_o,
    .debug_retire_pc_o,
    .debug_retire_instr_o,
    .debug_retire_redirect_valid_o,
    .debug_retire_redirect_target_o,
    .debug_retire_mem_valid_o,
    .debug_retire_mem_write_o,
    .debug_retire_mem_size_o,
    .debug_retire_mem_addr_o,
    .debug_retire_mem_wdata_o,
    .debug_retire_gpr_we_o,
    .debug_retire_gpr_waddr_o,
    .debug_retire_gpr_wdata_o,
    .debug_retire_mstatus_o,
    .debug_retire_mtvec_o,
    .debug_retire_mepc_o,
    .debug_retire_mcause_o,
    .debug_retire_mtval_o
  );

endmodule
