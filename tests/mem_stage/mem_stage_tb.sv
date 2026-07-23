// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module mem_stage_tb (
  input logic clk_i,
  input logic rst_ni,

  input logic ex_mem_valid_i,
  output logic ex_mem_ready_o,
  input logic [31:0] ex_mem_pc_i,
  input logic [31:0] ex_mem_instr_i,
  input logic ex_mem_mem_valid_i,
  input logic ex_mem_mem_write_i,
  input logic [1:0] ex_mem_mem_size_i,
  input logic ex_mem_mem_sign_ext_i,
  input logic [31:0] ex_mem_mem_addr_i,
  input logic [31:0] ex_mem_mem_wdata_i,
  input logic ex_mem_wb_valid_i,
  input logic ex_mem_wb_data_valid_i,
  input logic [4:0] ex_mem_wb_rd_addr_i,
  input logic [31:0] ex_mem_wb_wdata_i,

  output logic [31:0] dmem_req_addr_o,
  output logic dmem_req_write_o,
  output logic [1:0] dmem_req_size_o,
  output logic [31:0] dmem_req_wdata_o,
  output logic [3:0] dmem_req_wstrb_o,
  output logic dmem_req_valid_o,
  input logic dmem_req_ready_i,
  output logic dmem_rsp_ready_o,
  input logic [31:0] dmem_rsp_rdata_i,
  input logic dmem_rsp_error_i,
  input logic dmem_rsp_valid_i,

  output logic pending_0_valid_o,
  output logic [4:0] pending_0_rd_addr_o,
  output logic pending_1_valid_o,
  output logic [4:0] pending_1_rd_addr_o,

  output logic mem_wb_req_valid_o,
  output logic mem_wb_req_data_valid_o,
  output logic [4:0] mem_wb_req_rd_addr_o,
  output logic [31:0] mem_wb_req_wdata_o,
  output logic mem_wb_valid_o,
  input logic mem_wb_ready_i,
  output logic [31:0] mem_wb_pc_o,
  output logic [31:0] mem_wb_instr_o,
  output logic [1:0] mem_wb_mem_op_o,
  output logic [1:0] mem_wb_mem_size_o,
  output logic [31:0] mem_wb_mem_addr_o,
  output logic [31:0] mem_wb_mem_data_o,
  output logic mem_wb_exception_valid_o,
  output logic [3:0] mem_wb_exception_cause_o,
  output logic [31:0] mem_wb_exception_tval_o
);

  ex_mem_bus_t ex_mem_bus;
  core_bus_req_t dmem_req;
  core_bus_resp_t dmem_resp;
  logic pending_valid;
  reg_addr_t pending_rd_addr;
  wb_req_bus_t mem_wb_req;
  mem_wb_bus_t mem_wb_bus;

  always_comb begin
    ex_mem_bus = '0;
    ex_mem_bus.mem_req.valid = ex_mem_mem_valid_i;
    ex_mem_bus.mem_req.write = ex_mem_mem_write_i;
    ex_mem_bus.mem_req.size = mem_size_e'(ex_mem_mem_size_i);
    ex_mem_bus.mem_req.sign_ext = ex_mem_mem_sign_ext_i;
    ex_mem_bus.mem_req.addr = ex_mem_mem_addr_i;
    ex_mem_bus.mem_req.wdata = ex_mem_mem_wdata_i;
    ex_mem_bus.wb_req.valid = ex_mem_wb_valid_i;
    ex_mem_bus.wb_req.data_valid = ex_mem_wb_data_valid_i;
    ex_mem_bus.wb_req.rd_addr = ex_mem_wb_rd_addr_i;
    ex_mem_bus.wb_req.wdata = ex_mem_wb_wdata_i;
    ex_mem_bus.retire.instruction.pc = ex_mem_pc_i;
    ex_mem_bus.retire.instruction.instr = ex_mem_instr_i;
    ex_mem_bus.retire.mem_op = !ex_mem_mem_valid_i ? RETIRE_MEM_NONE :
        (ex_mem_mem_write_i ? RETIRE_MEM_WRITE : RETIRE_MEM_READ);
    ex_mem_bus.retire.mem_size = mem_size_e'(ex_mem_mem_size_i);
    ex_mem_bus.retire.mem_addr = ex_mem_mem_addr_i;
    ex_mem_bus.retire.mem_data = ex_mem_mem_wdata_i;
  end

  assign dmem_resp.req_ready = dmem_req_ready_i;
  assign dmem_resp.rsp.rdata = dmem_rsp_rdata_i;
  assign dmem_resp.rsp.error = dmem_rsp_error_i;
  assign dmem_resp.rsp_valid = dmem_rsp_valid_i;

  assign dmem_req_addr_o = dmem_req.req.addr;
  assign dmem_req_write_o = dmem_req.req.write;
  assign dmem_req_size_o = dmem_req.req.size;
  assign dmem_req_wdata_o = dmem_req.req.wdata;
  assign dmem_req_wstrb_o = dmem_req.req.wstrb;
  assign dmem_req_valid_o = dmem_req.req_valid;
  assign dmem_rsp_ready_o = dmem_req.rsp_ready;

  assign pending_0_valid_o = pending_valid;
  assign pending_0_rd_addr_o = pending_rd_addr;
  assign pending_1_valid_o = 1'b0;
  assign pending_1_rd_addr_o = '0;

  assign mem_wb_req_valid_o = mem_wb_req.valid;
  assign mem_wb_req_data_valid_o = mem_wb_req.data_valid;
  assign mem_wb_req_rd_addr_o = mem_wb_req.rd_addr;
  assign mem_wb_req_wdata_o = mem_wb_req.wdata;
  assign mem_wb_pc_o = mem_wb_bus.retire.instruction.pc;
  assign mem_wb_instr_o = mem_wb_bus.retire.instruction.instr;
  assign mem_wb_mem_op_o = mem_wb_bus.retire.mem_op;
  assign mem_wb_mem_size_o = mem_wb_bus.retire.mem_size;
  assign mem_wb_mem_addr_o = mem_wb_bus.retire.mem_addr;
  assign mem_wb_mem_data_o = mem_wb_bus.retire.mem_data;
  assign mem_wb_exception_valid_o = mem_wb_bus.exception.valid;
  assign mem_wb_exception_cause_o = mem_wb_bus.exception.cause;
  assign mem_wb_exception_tval_o = mem_wb_bus.exception.tval;

  mem_stage u_dut (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .side_effect_block_i(1'b0),
    .ex_mem_valid_i,
    .ex_mem_ready_o,
    .ex_mem_bus_i(ex_mem_bus),
    .dmem_req_o(dmem_req),
    .dmem_resp_i(dmem_resp),
    .mem_pending_valid_o(pending_valid),
    .mem_pending_rd_addr_o(pending_rd_addr),
    .mem_wb_req_o(mem_wb_req),
    .mem_wb_valid_o,
    .mem_wb_ready_i,
    .mem_wb_bus_o(mem_wb_bus),
    .busy_o()
  );

endmodule
