// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module id_stage_tb (
  input logic clk_i,
  input logic rst_ni,
  input logic if_id_valid_i,
  output logic if_id_ready_o,
  input logic [31:0] if_id_pc_i,
  input logic [31:0] if_id_instr_i,
  input logic wb_valid_i,
  input logic wb_data_valid_i,
  input logic [4:0] wb_rd_addr_i,
  input logic [31:0] wb_wdata_i,
  output logic id_ex_valid_o,
  input logic id_ex_ready_i,
  output logic [31:0] id_ex_pc_o,
  output logic [31:0] id_ex_instr_o,
  output logic [4:0] id_ex_rs1_addr_o,
  output logic [4:0] id_ex_rs2_addr_o,
  output logic [4:0] id_ex_rd_addr_o,
  output logic [31:0] id_ex_rs1_value_o,
  output logic [31:0] id_ex_rs2_value_o,
  output logic [31:0] id_ex_imm_o,
  output logic [3:0] id_ex_alu_op_o,
  output logic id_ex_op_a_sel_o,
  output logic id_ex_op_b_sel_o,
  output logic [3:0] id_ex_branch_op_o,
  output logic [1:0] id_ex_mem_cmd_o,
  output logic [1:0] id_ex_mem_size_o,
  output logic id_ex_mem_sign_ext_o,
  output logic [1:0] id_ex_wb_sel_o,
  output logic id_ex_rd_write_o,
  output logic id_ex_illegal_instr_o
);

  if_id_bus_t if_id_bus;
  wb_req_bus_t wb_req;
  id_ex_bus_t id_ex_bus;

  assign if_id_bus = '{
    fetch: '{pc: if_id_pc_i, instr: if_id_instr_i},
    debug: '{fetch: '{pc: if_id_pc_i, instr: if_id_instr_i}}
  };
  assign wb_req = '{valid: wb_valid_i, data_valid: wb_data_valid_i,
                    rd_addr: wb_rd_addr_i, wdata: wb_wdata_i};

  assign id_ex_pc_o = id_ex_bus.exec_data.pc;
  assign id_ex_instr_o = id_ex_bus.fetch.instr;
  assign id_ex_rs1_addr_o = id_ex_bus.reg_addr.rs1_addr;
  assign id_ex_rs2_addr_o = id_ex_bus.reg_addr.rs2_addr;
  assign id_ex_rd_addr_o = id_ex_bus.reg_addr.rd_addr;
  assign id_ex_rs1_value_o = id_ex_bus.exec_data.rs1_value;
  assign id_ex_rs2_value_o = id_ex_bus.exec_data.rs2_value;
  assign id_ex_imm_o = id_ex_bus.exec_data.imm;
  assign id_ex_alu_op_o = id_ex_bus.ctrl.alu_op;
  assign id_ex_op_a_sel_o = id_ex_bus.ctrl.op_a_sel;
  assign id_ex_op_b_sel_o = id_ex_bus.ctrl.op_b_sel;
  assign id_ex_branch_op_o = id_ex_bus.ctrl.branch_op;
  assign id_ex_mem_cmd_o = id_ex_bus.ctrl.mem_cmd;
  assign id_ex_mem_size_o = id_ex_bus.ctrl.mem_size;
  assign id_ex_mem_sign_ext_o = id_ex_bus.ctrl.mem_sign_ext;
  assign id_ex_wb_sel_o = id_ex_bus.ctrl.wb_sel;
  assign id_ex_rd_write_o = id_ex_bus.ctrl.rd_write;
  assign id_ex_illegal_instr_o = id_ex_bus.ctrl.illegal_instr;

  id_stage u_dut (
    .clk_i,
    .rst_ni,
    .if_id_valid_i,
    .if_id_ready_o,
    .if_id_bus_i(if_id_bus),
    .wb_req_i(wb_req),
    .id_ex_valid_o,
    .id_ex_ready_i,
    .id_ex_bus_o(id_ex_bus)
  );

endmodule
