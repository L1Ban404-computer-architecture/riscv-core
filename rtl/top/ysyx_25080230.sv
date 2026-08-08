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
  core_bus_req_t clint_req;
  core_bus_resp_t clint_resp;
  core_bus_req_t axi_dmem_req;
  core_bus_resp_t axi_dmem_resp;
  axi4_req_t icache_axi_req;
  axi4_resp_t icache_axi_resp;
  axi4_req_t dcache_axi_req;
  axi4_resp_t dcache_axi_resp;
  axi4_req_t master_axi_req;
  axi4_resp_t master_axi_resp;
  logic rst_ni;
  logic core_retire_valid /* verilator public_flat_rd */;
  core_retire_debug_bus_t core_retire_debug;
  core_performance_debug_bus_t core_performance_debug;

  logic [31:0] debug_retire_pc              /* verilator public_flat_rd */;
  logic [31:0] debug_retire_instr           /* verilator public_flat_rd */;
  logic [63:0] debug_retire_instid          /* verilator public_flat_rd */;
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
  logic [63:0] debug_perf_cycle_count       /* verilator public_flat_rd */;
  logic [63:0] debug_perf_instret_count     /* verilator public_flat_rd */;

  assign debug_retire_pc = core_retire_debug.pc;
  assign debug_retire_instr = core_retire_debug.instr;
  assign debug_retire_instid = core_retire_debug.instid;
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
  assign debug_perf_cycle_count = core_performance_debug.cycle_count;
  assign debug_perf_instret_count = core_performance_debug.instret_count;

  assign rst_ni = ~reset;

  // Keep packed AXI signals inside the design and expand them only at the
  // fixed public ysyx interface.
  assign io_master_awvalid = master_axi_req.awvalid;
  assign io_master_awaddr = master_axi_req.awaddr;
  assign io_master_awid = master_axi_req.awid;
  assign io_master_awlen = master_axi_req.awlen;
  assign io_master_awsize = master_axi_req.awsize;
  assign io_master_awburst = master_axi_req.awburst;
  assign io_master_wvalid = master_axi_req.wvalid;
  assign io_master_wdata = master_axi_req.wdata;
  assign io_master_wstrb = master_axi_req.wstrb;
  assign io_master_wlast = master_axi_req.wlast;
  assign io_master_bready = master_axi_req.bready;
  assign io_master_arvalid = master_axi_req.arvalid;
  assign io_master_araddr = master_axi_req.araddr;
  assign io_master_arid = master_axi_req.arid;
  assign io_master_arlen = master_axi_req.arlen;
  assign io_master_arsize = master_axi_req.arsize;
  assign io_master_arburst = master_axi_req.arburst;
  assign io_master_rready = master_axi_req.rready;

  assign master_axi_resp.awready = io_master_awready;
  assign master_axi_resp.wready = io_master_wready;
  assign master_axi_resp.bvalid = io_master_bvalid;
  assign master_axi_resp.bresp = io_master_bresp;
  assign master_axi_resp.bid = io_master_bid;
  assign master_axi_resp.arready = io_master_arready;
  assign master_axi_resp.rvalid = io_master_rvalid;
  assign master_axi_resp.rresp = io_master_rresp;
  assign master_axi_resp.rdata = io_master_rdata;
  assign master_axi_resp.rlast = io_master_rlast;
  assign master_axi_resp.rid = io_master_rid;

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
    .rst_ni,
    .boot_pc_i(32'h3000_0000),
    .imem_req_o(imem_req),
    .imem_resp_i(imem_resp),
    .dmem_req_o(dmem_req),
    .dmem_resp_i(dmem_resp),
    .core_retire_valid_o(core_retire_valid),
    .core_retire_debug_o(core_retire_debug),
    .core_performance_debug_o(core_performance_debug)
  );

  // CLINT is local to the processor and occupies the SoC-reserved
  // 0x0200_0000--0x0200_ffff region.  All other data traffic continues to the
  // external AXI master unchanged.
  corebus_addr_router #(
    .DeviceBase(32'h0200_0000),
    .DeviceMask(32'hffff_0000)
  ) u_dmem_router (
    .clk_i(clock),
    .rst_ni,
    .master_req_i(dmem_req),
    .master_resp_o(dmem_resp),
    .device_req_o(clint_req),
    .device_resp_i(clint_resp),
    .fallback_req_o(axi_dmem_req),
    .fallback_resp_i(axi_dmem_resp)
  );

  corebus_clint #(
    .MtimeAddr(32'h0200_bff8)
  ) u_clint (
    .clk_i(clock),
    .rst_ni,
    .req_i(clint_req),
    .resp_o(clint_resp)
  );

  icache u_icache (
    .clk_i(clock),
    .rst_ni,
    .core_req_i(imem_req),
    .core_resp_o(imem_resp),
    .axi_req_o(icache_axi_req),
    .axi_resp_i(icache_axi_resp)
  );

  dcache u_dcache (
    .clk_i(clock),
    .rst_ni,
    .core_req_i(axi_dmem_req),
    .core_resp_o(axi_dmem_resp),
    .axi_req_o(dcache_axi_req),
    .axi_resp_i(dcache_axi_resp)
  );

  cache_axi4_mux u_cache_axi4_mux (
    .clk_i(clock),
    .rst_ni,
    .icache_req_i(icache_axi_req),
    .icache_resp_o(icache_axi_resp),
    .dcache_req_i(dcache_axi_req),
    .dcache_resp_o(dcache_axi_resp),
    .master_req_o(master_axi_req),
    .master_resp_i(master_axi_resp)
  );

endmodule
