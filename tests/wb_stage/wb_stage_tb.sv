// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module wb_stage_tb (
  input logic clk_i,
  input logic rst_ni,

  input logic mem_wb_valid_i,
  output logic mem_wb_ready_o,

  input logic wb_valid_i,
  input logic wb_data_valid_i,
  input logic [4:0] wb_rd_addr_i,
  input logic [31:0] wb_wdata_i,

  input logic [31:0] fetch_pc_i,
  input logic [31:0] fetch_instr_i,
  input logic [31:0] commit_pc_i,
  input logic exception_valid_i,
  input logic redirect_valid_i,
  input logic [31:0] redirect_target_pc_i,
  input logic mem_req_valid_i,
  input logic mem_req_write_i,
  input logic [1:0] mem_req_size_i,
  input logic [31:0] mem_req_addr_i,
  input logic [31:0] mem_req_wdata_i,

  output logic wb_valid_o,
  output logic wb_data_valid_o,
  output logic [4:0] wb_rd_addr_o,
  output logic [31:0] wb_wdata_o,

  output logic retire_valid_o,
  output logic [31:0] retire_pc_o,
  output logic [31:0] retire_instr_o,
  output logic retire_redirect_valid_o,
  output logic [31:0] retire_redirect_target_pc_o,
  output logic [1:0] retire_mem_op_o,
  output logic [1:0] retire_mem_req_size_o,
  output logic [31:0] retire_mem_req_addr_o,
  output logic [31:0] retire_mem_data_o,
  output logic retire_gpr_we_o,
  output logic [4:0] retire_gpr_waddr_o,
  output logic [31:0] retire_gpr_wdata_o,
  output logic [63:0] state_cycle_count_o,
  output logic [63:0] state_instret_count_o,
  output logic state_trap_o,
  output logic [31:0] csr_mepc_o
);

  mem_wb_bus_t mem_wb_bus;
  wb_req_bus_t wb_req;
  logic core_retire_valid;
  core_retire_debug_bus_t core_retire_debug;
  core_state_debug_bus_t core_state_debug;
  csr_read_rsp_bus_t csr_read_rsp;
  pipeline_control_bus_t control;

  always_comb begin
    mem_wb_bus = '0;
    mem_wb_bus.wb_req.valid = wb_valid_i;
    mem_wb_bus.wb_req.data_valid = wb_data_valid_i;
    mem_wb_bus.wb_req.rd_addr = wb_rd_addr_i;
    mem_wb_bus.wb_req.wdata = wb_wdata_i;

    mem_wb_bus.pc = commit_pc_i;
    mem_wb_bus.exception.valid = exception_valid_i;
    mem_wb_bus.exception.cause = EXC_BREAKPOINT;
    mem_wb_bus.debug.pc = fetch_pc_i;
    mem_wb_bus.debug.instr = fetch_instr_i;
    mem_wb_bus.debug.redirect_valid = redirect_valid_i;
    mem_wb_bus.debug.redirect_target_pc = redirect_target_pc_i;
    mem_wb_bus.debug.mem_op = !mem_req_valid_i ? RETIRE_MEM_NONE :
        (mem_req_write_i ? RETIRE_MEM_WRITE : RETIRE_MEM_READ);
    mem_wb_bus.debug.mem_size = mem_size_e'(mem_req_size_i);
    mem_wb_bus.debug.mem_addr = mem_req_addr_i;
    mem_wb_bus.debug.mem_data = mem_req_wdata_i;
  end

  assign wb_valid_o = wb_req.valid;
  assign wb_data_valid_o = wb_req.data_valid;
  assign wb_rd_addr_o = wb_req.rd_addr;
  assign wb_wdata_o = wb_req.wdata;

  assign retire_valid_o = core_retire_valid;
  assign retire_pc_o = core_retire_debug.pc;
  assign retire_instr_o = core_retire_debug.instr;
  assign retire_redirect_valid_o = core_retire_debug.redirect_valid;
  assign retire_redirect_target_pc_o = core_retire_debug.redirect_target_pc;
  assign retire_mem_op_o = core_retire_debug.mem_op;
  assign retire_mem_req_size_o = core_retire_debug.mem_size;
  assign retire_mem_req_addr_o = core_retire_debug.mem_addr;
  assign retire_mem_data_o = core_retire_debug.mem_data;
  assign retire_gpr_we_o = core_retire_debug.gpr_we;
  assign retire_gpr_waddr_o = core_retire_debug.gpr_waddr;
  assign retire_gpr_wdata_o = core_retire_debug.gpr_wdata;
  assign state_cycle_count_o = core_state_debug.cycle_count;
  assign state_instret_count_o = core_state_debug.instret_count;
  assign state_trap_o = core_state_debug.trap;
  assign csr_mepc_o = csr_read_rsp.data;

  wb_stage u_dut (
    .clk_i,
    .rst_ni,
    .mem_wb_valid_i,
    .mem_wb_ready_o,
    .mem_wb_bus_i(mem_wb_bus),
    .csr_read_addr_i(CsrMepc),
    .csr_read_rsp_o(csr_read_rsp),
    .control_o(control),
    .wb_req_o(wb_req),
    .core_retire_valid_o(core_retire_valid),
    .core_retire_debug_o(core_retire_debug),
    .core_state_debug_o(core_state_debug)
  );

endmodule
