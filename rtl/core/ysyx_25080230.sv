// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module ysyx_25080230 (
  input         clock,
  input         reset,
  input         io_interrupt,

  input         io_master_awready,
  output        io_master_awvalid,
  output [31:0] io_master_awaddr,
  output [3:0]  io_master_awid,
  output [7:0]  io_master_awlen,
  output [2:0]  io_master_awsize,
  output [1:0]  io_master_awburst,
  input         io_master_wready,
  output        io_master_wvalid,
  output [31:0] io_master_wdata,
  output [3:0]  io_master_wstrb,
  output        io_master_wlast,
  output        io_master_bready,
  input         io_master_bvalid,
  input  [1:0]  io_master_bresp,
  input  [3:0]  io_master_bid,
  input         io_master_arready,
  output        io_master_arvalid,
  output [31:0] io_master_araddr,
  output [3:0]  io_master_arid,
  output [7:0]  io_master_arlen,
  output [2:0]  io_master_arsize,
  output [1:0]  io_master_arburst,
  output        io_master_rready,
  input         io_master_rvalid,
  input  [1:0]  io_master_rresp,
  input  [31:0] io_master_rdata,
  input         io_master_rlast,
  input  [3:0]  io_master_rid,

  output        io_slave_awready,
  input         io_slave_awvalid,
  input  [31:0] io_slave_awaddr,
  input  [3:0]  io_slave_awid,
  input  [7:0]  io_slave_awlen,
  input  [2:0]  io_slave_awsize,
  input  [1:0]  io_slave_awburst,
  output        io_slave_wready,
  input         io_slave_wvalid,
  input  [31:0] io_slave_wdata,
  input  [3:0]  io_slave_wstrb,
  input         io_slave_wlast,
  input         io_slave_bready,
  output        io_slave_bvalid,
  output [1:0]  io_slave_bresp,
  output [3:0]  io_slave_bid,
  output        io_slave_arready,
  input         io_slave_arvalid,
  input  [31:0] io_slave_araddr,
  input  [3:0]  io_slave_arid,
  input  [7:0]  io_slave_arlen,
  input  [2:0]  io_slave_arsize,
  input  [1:0]  io_slave_arburst,
  input         io_slave_rready,
  output        io_slave_rvalid,
  output [1:0]  io_slave_rresp,
  output [31:0] io_slave_rdata,
  output        io_slave_rlast,
  output [3:0]  io_slave_rid
);

  core_bus_req_t imem_req;
  core_bus_resp_t imem_resp;
  core_bus_req_t dmem_req;
  core_bus_resp_t dmem_resp;
  logic core_retire_valid /* verilator public_flat_rd */;
  core_retire_debug_bus_t core_retire_debug;
  core_state_debug_bus_t core_state_debug;

  logic [31:0] debug_retire_pc              /* verilator public_flat_rd */;
  logic [31:0] debug_retire_instr           /* verilator public_flat_rd */;
  logic        debug_retire_redirect_valid  /* verilator public_flat_rd */;
  logic [31:0] debug_retire_redirect_target /* verilator public_flat_rd */;
  logic [1:0]  debug_retire_mem_op          /* verilator public_flat_rd */;
  logic [1:0]  debug_retire_mem_size        /* verilator public_flat_rd */;
  logic [31:0] debug_retire_mem_addr        /* verilator public_flat_rd */;
  logic [31:0] debug_retire_mem_data        /* verilator public_flat_rd */;
  logic        debug_retire_gpr_we          /* verilator public_flat_rd */;
  logic [4:0]  debug_retire_gpr_waddr       /* verilator public_flat_rd */;
  logic [31:0] debug_retire_gpr_wdata       /* verilator public_flat_rd */;
  logic [31:0] debug_retire_mstatus         /* verilator public_flat_rd */;
  logic [31:0] debug_retire_mtvec           /* verilator public_flat_rd */;
  logic [31:0] debug_retire_mepc            /* verilator public_flat_rd */;
  logic [31:0] debug_retire_mcause          /* verilator public_flat_rd */;
  logic [31:0] debug_retire_mtval           /* verilator public_flat_rd */;
  logic        debug_state_trap             /* verilator public_flat_rd */;
  logic        debug_state_intr             /* verilator public_flat_rd */;
  logic [31:0] debug_state_cause            /* verilator public_flat_rd */;
  logic [31:0] debug_state_tval             /* verilator public_flat_rd */;
  logic [63:0] debug_state_cycle_count      /* verilator public_flat_rd */;
  logic [63:0] debug_state_instret_count    /* verilator public_flat_rd */;

  assign debug_retire_pc = core_retire_debug.pc;
  assign debug_retire_instr = core_retire_debug.instr;
  assign debug_retire_redirect_valid = core_retire_debug.redirect_valid;
  assign debug_retire_redirect_target = core_retire_debug.redirect_target_pc;
  assign debug_retire_mem_op = core_retire_debug.mem_op;
  assign debug_retire_mem_size = core_retire_debug.mem_size;
  assign debug_retire_mem_addr = core_retire_debug.mem_addr;
  assign debug_retire_mem_data = core_retire_debug.mem_data;
  assign debug_retire_gpr_we = core_retire_debug.gpr_we;
  assign debug_retire_gpr_waddr = core_retire_debug.gpr_waddr;
  assign debug_retire_gpr_wdata = core_retire_debug.gpr_wdata;
  assign debug_retire_mstatus = core_retire_debug.csr.mstatus;
  assign debug_retire_mtvec = core_retire_debug.csr.mtvec;
  assign debug_retire_mepc = core_retire_debug.csr.mepc;
  assign debug_retire_mcause = core_retire_debug.csr.mcause;
  assign debug_retire_mtval = core_retire_debug.csr.mtval;
  assign debug_state_trap = core_state_debug.trap;
  assign debug_state_intr = core_state_debug.intr;
  assign debug_state_cause = core_state_debug.cause;
  assign debug_state_tval = core_state_debug.tval;
  assign debug_state_cycle_count = core_state_debug.cycle_count;
  assign debug_state_instret_count = core_state_debug.instret_count;

  assign io_slave_awready = 1'b0;
  assign io_slave_wready = 1'b0;
  assign io_slave_bvalid = 1'b0;
  assign io_slave_bresp = 2'b00;
  assign io_slave_bid = 4'b0;
  assign io_slave_arready = 1'b0;
  assign io_slave_rvalid = 1'b0;
  assign io_slave_rresp = 2'b00;
  assign io_slave_rdata = 32'b0;
  assign io_slave_rlast = 1'b0;
  assign io_slave_rid = 4'b0;

  logic unused_inputs;
  assign unused_inputs = ^{io_interrupt, io_slave_awvalid, io_slave_awaddr,
                           io_slave_awid, io_slave_awlen, io_slave_awsize,
                           io_slave_awburst, io_slave_wvalid, io_slave_wdata,
                           io_slave_wstrb, io_slave_wlast, io_slave_bready,
                           io_slave_arvalid, io_slave_araddr, io_slave_arid,
                           io_slave_arlen, io_slave_arsize, io_slave_arburst,
                           io_slave_rready};

  riscv_core_impl u_core (
    .clk_i(clock),
    .rst_ni(~reset),
    .boot_pc_i(32'h3000_0000),
    .imem_req_o(imem_req),
    .imem_resp_i(imem_resp),
    .dmem_req_o(dmem_req),
    .dmem_resp_i(dmem_resp),
    .core_retire_valid_o(core_retire_valid),
    .core_retire_debug_o(core_retire_debug),
    .core_state_debug_o(core_state_debug)
  );

  corebus_axi4 u_axi4 (
    .clock,
    .reset,
    .imem_req_valid_i(imem_req.req_valid),
    .imem_req_ready_o(imem_resp.req_ready),
    .imem_req_addr_i(imem_req.req.addr),
    .imem_req_wdata_i(imem_req.req.wdata),
    .imem_req_wstrb_i(imem_req.req.wstrb),
    .imem_rsp_valid_o(imem_resp.rsp_valid),
    .imem_rsp_ready_i(imem_req.rsp_ready),
    .imem_rsp_rdata_o(imem_resp.rsp.rdata),
    .imem_rsp_error_o(imem_resp.rsp.error),
    .dmem_req_valid_i(dmem_req.req_valid),
    .dmem_req_ready_o(dmem_resp.req_ready),
    .dmem_req_addr_i(dmem_req.req.addr),
    .dmem_req_wdata_i(dmem_req.req.wdata),
    .dmem_req_wstrb_i(dmem_req.req.wstrb),
    .dmem_rsp_valid_o(dmem_resp.rsp_valid),
    .dmem_rsp_ready_i(dmem_req.rsp_ready),
    .dmem_rsp_rdata_o(dmem_resp.rsp.rdata),
    .dmem_rsp_error_o(dmem_resp.rsp.error),
    .m_awready_i(io_master_awready),
    .m_awvalid_o(io_master_awvalid),
    .m_awaddr_o(io_master_awaddr),
    .m_awid_o(io_master_awid),
    .m_awlen_o(io_master_awlen),
    .m_awsize_o(io_master_awsize),
    .m_awburst_o(io_master_awburst),
    .m_wready_i(io_master_wready),
    .m_wvalid_o(io_master_wvalid),
    .m_wdata_o(io_master_wdata),
    .m_wstrb_o(io_master_wstrb),
    .m_wlast_o(io_master_wlast),
    .m_bready_o(io_master_bready),
    .m_bvalid_i(io_master_bvalid),
    .m_bresp_i(io_master_bresp),
    .m_bid_i(io_master_bid),
    .m_arready_i(io_master_arready),
    .m_arvalid_o(io_master_arvalid),
    .m_araddr_o(io_master_araddr),
    .m_arid_o(io_master_arid),
    .m_arlen_o(io_master_arlen),
    .m_arsize_o(io_master_arsize),
    .m_arburst_o(io_master_arburst),
    .m_rready_o(io_master_rready),
    .m_rvalid_i(io_master_rvalid),
    .m_rresp_i(io_master_rresp),
    .m_rdata_i(io_master_rdata),
    .m_rlast_i(io_master_rlast),
    .m_rid_i(io_master_rid)
  );

endmodule
