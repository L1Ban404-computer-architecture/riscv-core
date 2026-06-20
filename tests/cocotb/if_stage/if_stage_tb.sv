// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module if_stage_tb #(
  parameter int unsigned FetchOutstandingDepth = 4,
  parameter int unsigned IfIdQueueDepth = 2
) (
  input logic clk_i,
  input logic rst_ni,

  input pc_t boot_pc_i,

  input logic redirect_valid_i,
  input pc_t redirect_target_pc_i,

  output logic [31:0] imem_aw_addr_o,
  output logic [2:0] imem_aw_prot_o,
  output logic imem_aw_valid_o,
  output logic [31:0] imem_w_data_o,
  output logic [3:0] imem_w_strb_o,
  output logic imem_w_valid_o,
  output logic imem_b_ready_o,

  output logic [31:0] imem_ar_addr_o,
  output logic [2:0] imem_ar_prot_o,
  output logic imem_ar_valid_o,
  input logic imem_ar_ready_i,

  input logic [31:0] imem_r_data_i,
  input logic [1:0] imem_r_resp_i,
  input logic imem_r_valid_i,
  output logic imem_r_ready_o,

  output logic if_id_valid_o,
  input logic if_id_ready_i,
  output logic [31:0] if_id_pc_o,
  output logic [31:0] if_id_instr_o,
  output logic [31:0] if_id_debug_pc_o,
  output logic [31:0] if_id_debug_instr_o
);

  axi_lite_req_t imem_req;
  axi_lite_resp_t imem_resp;
  if_id_bus_t if_id_bus;
  redirect_bus_t redirect_bus;

  assign redirect_bus.valid = redirect_valid_i;
  assign redirect_bus.target_pc = redirect_target_pc_i;
  assign redirect_bus.reason = REDIR_BRANCH;

  assign imem_resp.aw_ready = 1'b0;
  assign imem_resp.w_ready = 1'b0;
  assign imem_resp.b.resp = AXI_RESP_OKAY;
  assign imem_resp.b_valid = 1'b0;
  assign imem_resp.ar_ready = imem_ar_ready_i;
  assign imem_resp.r.data = imem_r_data_i;
  assign imem_resp.r.resp = axi_lite_resp_e'(imem_r_resp_i);
  assign imem_resp.r_valid = imem_r_valid_i;

  assign imem_aw_addr_o = imem_req.aw.addr;
  assign imem_aw_prot_o = imem_req.aw.prot;
  assign imem_aw_valid_o = imem_req.aw_valid;
  assign imem_w_data_o = imem_req.w.data;
  assign imem_w_strb_o = imem_req.w.strb;
  assign imem_w_valid_o = imem_req.w_valid;
  assign imem_b_ready_o = imem_req.b_ready;
  assign imem_ar_addr_o = imem_req.ar.addr;
  assign imem_ar_prot_o = imem_req.ar.prot;
  assign imem_ar_valid_o = imem_req.ar_valid;
  assign imem_r_ready_o = imem_req.r_ready;

  assign if_id_pc_o = if_id_bus.fetch.pc;
  assign if_id_instr_o = if_id_bus.fetch.instr;
  assign if_id_debug_pc_o = if_id_bus.debug.fetch.pc;
  assign if_id_debug_instr_o = if_id_bus.debug.fetch.instr;

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
