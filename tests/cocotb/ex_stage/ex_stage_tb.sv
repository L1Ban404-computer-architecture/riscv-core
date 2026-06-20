// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module ex_stage_tb (
  input logic clk_i,
  input logic rst_ni,

  input logic id_ex_valid_i,
  output logic id_ex_ready_o,
  input logic [31:0] id_ex_pc_i,
  input logic [31:0] id_ex_instr_i,
  input logic [4:0] id_ex_rs1_addr_i,
  input logic [4:0] id_ex_rs2_addr_i,
  input logic [4:0] id_ex_rd_addr_i,
  input logic [31:0] id_ex_rs1_value_i,
  input logic [31:0] id_ex_rs2_value_i,
  input logic [31:0] id_ex_imm_i,
  input logic [3:0] id_ex_alu_op_i,
  input logic id_ex_op_a_sel_i,
  input logic id_ex_op_b_sel_i,
  input logic [3:0] id_ex_branch_op_i,
  input logic [1:0] id_ex_mem_cmd_i,
  input logic [1:0] id_ex_mem_size_i,
  input logic id_ex_mem_sign_ext_i,
  input logic [1:0] id_ex_wb_sel_i,
  input logic id_ex_rd_write_i,
  input logic id_ex_illegal_instr_i,

  input logic mem_wb_valid_i,
  input logic mem_wb_data_valid_i,
  input logic [4:0] mem_wb_rd_addr_i,
  input logic [31:0] mem_wb_wdata_i,

  output logic redirect_valid_o,
  output logic [31:0] redirect_target_pc_o,
  output logic [2:0] redirect_reason_o,

  output logic ex_mem_valid_o,
  input logic ex_mem_ready_i,
  output logic [31:0] ex_mem_pc_o,
  output logic [31:0] ex_mem_instr_o,
  output logic ex_mem_mem_valid_o,
  output logic ex_mem_mem_write_o,
  output logic [1:0] ex_mem_mem_size_o,
  output logic ex_mem_mem_sign_ext_o,
  output logic [31:0] ex_mem_mem_addr_o,
  output logic [31:0] ex_mem_mem_wdata_o,
  output logic ex_mem_wb_valid_o,
  output logic ex_mem_wb_data_valid_o,
  output logic [4:0] ex_mem_wb_rd_addr_o,
  output logic [31:0] ex_mem_wb_wdata_o,
  output logic ex_mem_debug_redirect_valid_o,
  output logic [31:0] ex_mem_debug_redirect_target_o,
  output logic [2:0] ex_mem_debug_redirect_reason_o,
  output logic [31:0] ex_mem_debug_alu_result_o
);

  id_ex_bus_t id_ex_bus;
  wb_req_bus_t mem_wb_req;
  redirect_bus_t redirect;
  ex_mem_bus_t ex_mem_bus;

  always_comb begin
    id_ex_bus = '0;
    id_ex_bus.fetch.pc = id_ex_pc_i;
    id_ex_bus.fetch.instr = id_ex_instr_i;
    id_ex_bus.reg_addr.rs1_addr = id_ex_rs1_addr_i;
    id_ex_bus.reg_addr.rs2_addr = id_ex_rs2_addr_i;
    id_ex_bus.reg_addr.rd_addr = id_ex_rd_addr_i;
    id_ex_bus.exec_data.pc = id_ex_pc_i;
    id_ex_bus.exec_data.rs1_value = id_ex_rs1_value_i;
    id_ex_bus.exec_data.rs2_value = id_ex_rs2_value_i;
    id_ex_bus.exec_data.imm = id_ex_imm_i;
    id_ex_bus.ctrl.alu_op = alu_op_e'(id_ex_alu_op_i);
    id_ex_bus.ctrl.op_a_sel = op_a_sel_e'(id_ex_op_a_sel_i);
    id_ex_bus.ctrl.op_b_sel = op_b_sel_e'(id_ex_op_b_sel_i);
    id_ex_bus.ctrl.branch_op = branch_op_e'(id_ex_branch_op_i);
    id_ex_bus.ctrl.mem_cmd = mem_cmd_e'(id_ex_mem_cmd_i);
    id_ex_bus.ctrl.mem_size = mem_size_e'(id_ex_mem_size_i);
    id_ex_bus.ctrl.mem_sign_ext = id_ex_mem_sign_ext_i;
    id_ex_bus.ctrl.wb_sel = wb_sel_e'(id_ex_wb_sel_i);
    id_ex_bus.ctrl.rd_write = id_ex_rd_write_i;
    id_ex_bus.ctrl.illegal_instr = id_ex_illegal_instr_i;
    id_ex_bus.debug.if_debug.fetch = id_ex_bus.fetch;
    id_ex_bus.debug.reg_addr = id_ex_bus.reg_addr;
    id_ex_bus.debug.ctrl = id_ex_bus.ctrl;
  end

  assign mem_wb_req = '{valid: mem_wb_valid_i,
                        data_valid: mem_wb_data_valid_i,
                        rd_addr: mem_wb_rd_addr_i,
                        wdata: mem_wb_wdata_i};

  assign redirect_valid_o = redirect.valid;
  assign redirect_target_pc_o = redirect.target_pc;
  assign redirect_reason_o = redirect.reason;

  assign ex_mem_pc_o = ex_mem_bus.debug.id_debug.if_debug.fetch.pc;
  assign ex_mem_instr_o = ex_mem_bus.debug.id_debug.if_debug.fetch.instr;
  assign ex_mem_mem_valid_o = ex_mem_bus.mem_req.valid;
  assign ex_mem_mem_write_o = ex_mem_bus.mem_req.write;
  assign ex_mem_mem_size_o = ex_mem_bus.mem_req.size;
  assign ex_mem_mem_sign_ext_o = ex_mem_bus.mem_req.sign_ext;
  assign ex_mem_mem_addr_o = ex_mem_bus.mem_req.addr;
  assign ex_mem_mem_wdata_o = ex_mem_bus.mem_req.wdata;
  assign ex_mem_wb_valid_o = ex_mem_bus.wb_req.valid;
  assign ex_mem_wb_data_valid_o = ex_mem_bus.wb_req.data_valid;
  assign ex_mem_wb_rd_addr_o = ex_mem_bus.wb_req.rd_addr;
  assign ex_mem_wb_wdata_o = ex_mem_bus.wb_req.wdata;
  assign ex_mem_debug_redirect_valid_o = ex_mem_bus.debug.redirect.valid;
  assign ex_mem_debug_redirect_target_o = ex_mem_bus.debug.redirect.target_pc;
  assign ex_mem_debug_redirect_reason_o = ex_mem_bus.debug.redirect.reason;
  assign ex_mem_debug_alu_result_o = ex_mem_bus.debug.alu_result;

  ex_stage u_dut (
    .clk_i,
    .rst_ni,
    .id_ex_valid_i,
    .id_ex_ready_o,
    .id_ex_bus_i(id_ex_bus),
    .mem_wb_req_i(mem_wb_req),
    .redirect_o(redirect),
    .ex_mem_valid_o,
    .ex_mem_ready_i,
    .ex_mem_bus_o(ex_mem_bus)
  );

endmodule
