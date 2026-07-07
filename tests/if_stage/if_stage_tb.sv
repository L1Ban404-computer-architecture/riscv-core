// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module if_stage_tb #(
  parameter int unsigned FetchOutstandingDepth = 1,
  parameter int unsigned IfIdQueueDepth = 2
) (
  input logic clk_i,
  input logic rst_ni,

  input pc_t boot_pc_i,

  input logic redirect_valid_i,
  input pc_t redirect_target_pc_i,

  output logic [31:0] imem_req_addr_o,
  output logic [31:0] imem_req_wdata_o,
  output logic [3:0] imem_req_wstrb_o,
  output logic imem_req_valid_o,
  input logic imem_req_ready_i,

  input logic [31:0] imem_rsp_rdata_i,
  input logic imem_rsp_error_i,
  input logic imem_rsp_valid_i,
  output logic imem_rsp_ready_o,

  output logic if_id_valid_o,
  input logic if_id_ready_i,
  output logic [31:0] if_id_pc_o,
  output logic [31:0] if_id_instr_o,
  output logic [31:0] if_id_debug_pc_o,
  output logic [31:0] if_id_debug_instr_o
);

  core_bus_req_t imem_req;
  core_bus_resp_t imem_resp;
  if_id_bus_t if_id_bus;
  redirect_bus_t redirect_bus;

  assign redirect_bus.valid = redirect_valid_i;
  assign redirect_bus.target_pc = redirect_target_pc_i;
  assign redirect_bus.reason = REDIR_BRANCH;

  assign imem_resp.req_ready = imem_req_ready_i;
  assign imem_resp.rsp.rdata = imem_rsp_rdata_i;
  assign imem_resp.rsp.error = imem_rsp_error_i;
  assign imem_resp.rsp_valid = imem_rsp_valid_i;

  assign imem_req_addr_o = imem_req.req.addr;
  assign imem_req_wdata_o = imem_req.req.wdata;
  assign imem_req_wstrb_o = imem_req.req.wstrb;
  assign imem_req_valid_o = imem_req.req_valid;
  assign imem_rsp_ready_o = imem_req.rsp_ready;

  assign if_id_pc_o = if_id_bus.fetch.pc;
  assign if_id_instr_o = if_id_bus.fetch.instr;
  assign if_id_debug_pc_o = if_id_bus.debug.pc;
  assign if_id_debug_instr_o = if_id_bus.debug.instr;

  if_stage #(
    .FetchOutstandingDepth(FetchOutstandingDepth),
    .IfIdQueueDepth(IfIdQueueDepth)
  ) u_dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .boot_pc_i(boot_pc_i),
    .redirect_i(redirect_bus),
    .imem_req_o(imem_req),
    .imem_resp_i(imem_resp),
    .if_id_valid_o(if_id_valid_o),
    .if_id_ready_i(if_id_ready_i),
    .if_id_bus_o(if_id_bus)
  );

endmodule
