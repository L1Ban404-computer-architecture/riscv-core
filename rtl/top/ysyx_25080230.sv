// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// ysyx SoC 集成顶层。
//
// 连接 RV32 核心、I/D Cache、AXI4 汇聚器和片内 CLINT，并将参数化内部接口
// 适配为评测平台规定的固定引脚。
// 外部 AXI4 主接口固定为 32 位地址/数据和 4 位 ID；外部从接口当前停用；
// CLINT 占用 0x0200_0000～0x0200_ffff，其余数据访问转发至外部主接口。
module ysyx_25080230
  import riscv_bus_pkg::*;
  import riscv_core_pkg::*;
(
  // 全局控制
  input         clock,
  input         reset,
  input         io_interrupt,

  // 外部 AXI4 主接口
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

  // 外部 AXI4 从接口
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

  ////////////////////////
  // 内部总线与调试接口 //
  ////////////////////////

  core_bus_if imem_bus();
  core_bus_if dmem_bus();
  core_bus_if clint_bus();
  core_bus_if axi_dmem_bus();
  axi4_if icache_axi();
  axi4_if dcache_axi();
  axi4_if master_axi();
  logic rst_ni;
  logic core_retire_valid /* verilator public_flat_rd */;
  retire_debug_if retire_debug();
  performance_debug_if performance_debug();

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
  logic [63:0] debug_perf_if_id_fire_count  /* verilator public_flat_rd */;
  logic [63:0] debug_perf_id_ex_fire_count  /* verilator public_flat_rd */;
  logic [63:0] debug_perf_ex_mem_fire_count /* verilator public_flat_rd */;
  logic [63:0] debug_perf_mem_wb_fire_count /* verilator public_flat_rd */;
  logic [63:0] debug_perf_if_id_stall_cycle_count
      /* verilator public_flat_rd */;
  logic [63:0] debug_perf_id_ex_stall_cycle_count
      /* verilator public_flat_rd */;
  logic [63:0] debug_perf_ex_mem_stall_cycle_count
      /* verilator public_flat_rd */;
  logic [63:0] debug_perf_mem_wb_stall_cycle_count
      /* verilator public_flat_rd */;
  logic [63:0] debug_perf_if_starve_cycle_count
      /* verilator public_flat_rd */;
  logic [63:0] debug_perf_id_local_stall_cycle_count
      /* verilator public_flat_rd */;
  logic [63:0] debug_perf_ex_local_stall_cycle_count
      /* verilator public_flat_rd */;
  logic [63:0] debug_perf_mem_local_stall_cycle_count
      /* verilator public_flat_rd */;
  logic [63:0] debug_perf_wb_local_stall_cycle_count
      /* verilator public_flat_rd */;

  ////////////////////////
  // 退休与性能观测信号 //
  ////////////////////////

  assign debug_retire_pc = retire_debug.pc;
  assign debug_retire_instr = retire_debug.instr;
  assign debug_retire_instid = retire_debug.instid;
  assign debug_retire_redirect_valid = retire_debug.redirect_valid;
  assign debug_retire_redirect_target = retire_debug.redirect_target_pc;
  assign debug_retire_mem_op = retire_debug.mem_op;
  assign debug_retire_mem_size = retire_debug.mem_size;
  assign debug_retire_mem_addr = retire_debug.mem_addr;
  assign debug_retire_mem_data = retire_debug.mem_data;
  assign debug_retire_gpr_we = retire_debug.gpr_we;
  assign debug_retire_gpr_waddr = retire_debug.gpr_waddr;
  assign debug_retire_gpr_wdata = retire_debug.gpr_wdata;
  assign debug_retire_mstatus = retire_debug.csr_mstatus;
  assign debug_retire_mtvec = retire_debug.csr_mtvec;
  assign debug_retire_mepc = retire_debug.csr_mepc;
  assign debug_retire_mcause = retire_debug.csr_mcause;
  assign debug_retire_mtval = retire_debug.csr_mtval;
  assign debug_perf_cycle_count = performance_debug.cycle_count;
  assign debug_perf_instret_count = performance_debug.instret_count;
  assign debug_perf_if_id_fire_count = performance_debug.if_id_fire_count;
  assign debug_perf_id_ex_fire_count = performance_debug.id_ex_fire_count;
  assign debug_perf_ex_mem_fire_count = performance_debug.ex_mem_fire_count;
  assign debug_perf_mem_wb_fire_count = performance_debug.mem_wb_fire_count;
  assign debug_perf_if_id_stall_cycle_count =
      performance_debug.if_id_stall_cycle_count;
  assign debug_perf_id_ex_stall_cycle_count =
      performance_debug.id_ex_stall_cycle_count;
  assign debug_perf_ex_mem_stall_cycle_count =
      performance_debug.ex_mem_stall_cycle_count;
  assign debug_perf_mem_wb_stall_cycle_count =
      performance_debug.mem_wb_stall_cycle_count;
  assign debug_perf_if_starve_cycle_count = performance_debug.if_starve_cycle_count;
  assign debug_perf_id_local_stall_cycle_count =
      performance_debug.id_local_stall_cycle_count;
  assign debug_perf_ex_local_stall_cycle_count =
      performance_debug.ex_local_stall_cycle_count;
  assign debug_perf_mem_local_stall_cycle_count =
      performance_debug.mem_local_stall_cycle_count;
  assign debug_perf_wb_local_stall_cycle_count =
      performance_debug.wb_local_stall_cycle_count;

  assign rst_ni = ~reset;
  assign core_retire_valid = retire_debug.valid;

  ////////////////////////
  // 外部 AXI4 接口适配 //
  ////////////////////////

  // 主接口逐字段适配，外部从接口保持停用。
  assign io_master_awvalid = master_axi.awvalid;
  assign io_master_awaddr = master_axi.awaddr;
  assign io_master_awid = master_axi.awid;
  assign io_master_awlen = master_axi.awlen;
  assign io_master_awsize = master_axi.awsize;
  assign io_master_awburst = master_axi.awburst;
  assign io_master_wvalid = master_axi.wvalid;
  assign io_master_wdata = master_axi.wdata;
  assign io_master_wstrb = master_axi.wstrb;
  assign io_master_wlast = master_axi.wlast;
  assign io_master_bready = master_axi.bready;
  assign io_master_arvalid = master_axi.arvalid;
  assign io_master_araddr = master_axi.araddr;
  assign io_master_arid = master_axi.arid;
  assign io_master_arlen = master_axi.arlen;
  assign io_master_arsize = master_axi.arsize;
  assign io_master_arburst = master_axi.arburst;
  assign io_master_rready = master_axi.rready;

  assign master_axi.awready = io_master_awready;
  assign master_axi.wready = io_master_wready;
  assign master_axi.bvalid = io_master_bvalid;
  assign master_axi.bresp = io_master_bresp;
  assign master_axi.bid = io_master_bid;
  assign master_axi.arready = io_master_arready;
  assign master_axi.rvalid = io_master_rvalid;
  assign master_axi.rresp = io_master_rresp;
  assign master_axi.rdata = io_master_rdata;
  assign master_axi.rlast = io_master_rlast;
  assign master_axi.rid = io_master_rid;

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

  ////////////////////////
  // 核心与片上互连实例 //
  ////////////////////////

  riscv_core_impl u_core (
    .clk_i(clock),
    .rst_ni,
    .boot_pc_i(32'h3000_0000),
    .imem(imem_bus),
    .dmem(dmem_bus),
    .debug_retire(retire_debug),
    .performance(performance_debug)
  );

  corebus_addr_router #(
    .DeviceBase(32'h0200_0000),
    .DeviceMask(32'hffff_0000)
  ) u_dmem_router (
    .clk_i(clock),
    .rst_ni,
    .master_bus(dmem_bus),
    .device_bus(clint_bus),
    .fallback_bus(axi_dmem_bus)
  );

  corebus_clint #(
    .MtimeAddr(32'h0200_bff8)
  ) u_clint (
    .clk_i(clock),
    .rst_ni,
    .core_bus(clint_bus)
  );

  icache u_icache (
    .clk_i(clock),
    .rst_ni,
    .core_bus(imem_bus),
    .axi(icache_axi)
  );

  dcache u_dcache (
    .clk_i(clock),
    .rst_ni,
    .core_bus(axi_dmem_bus),
    .axi(dcache_axi)
  );

  cache_axi4_mux u_cache_axi4_mux (
    .clk_i(clock),
    .rst_ni,
    .icache_axi,
    .dcache_axi,
    .master_axi
  );

endmodule
