// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

// CoreBus 与 AXI4 接口。
//
// 集中定义参数化协议信号，并通过 modport 区分主设备、从设备和监视端方向。

///////////////////////////
// CoreBus 请求/响应接口 //
///////////////////////////

interface core_bus_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  localparam int unsigned StrbWidth = DataWidth / 8
);
  logic [AddrWidth-1:0] addr;
  logic write;
  riscv_bus_pkg::core_bus_size_e size;
  logic [DataWidth-1:0] wdata;
  logic [StrbWidth-1:0] wstrb;
  logic req_valid;
  logic req_ready;
  logic [DataWidth-1:0] rdata;
  logic error;
  logic rsp_valid;
  logic rsp_ready;

  modport master (
    output addr, write, size, wdata, wstrb, req_valid, rsp_ready,
    input req_ready, rdata, error, rsp_valid
  );
  modport slave (
    input addr, write, size, wdata, wstrb, req_valid, rsp_ready,
    output req_ready, rdata, error, rsp_valid
  );
  modport monitor (
    input addr, write, size, wdata, wstrb, req_valid, req_ready,
          rdata, error, rsp_valid, rsp_ready
  );
endinterface

/////////////////////
// AXI4 五通道接口 //
/////////////////////

interface axi4_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4,
  localparam int unsigned StrbWidth = DataWidth / 8
);
  logic awvalid;
  logic awready;
  logic [AddrWidth-1:0] awaddr;
  logic [IdWidth-1:0] awid;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [1:0] awburst;

  logic wvalid;
  logic wready;
  logic [DataWidth-1:0] wdata;
  logic [StrbWidth-1:0] wstrb;
  logic wlast;

  logic bvalid;
  logic bready;
  logic [1:0] bresp;
  logic [IdWidth-1:0] bid;

  logic arvalid;
  logic arready;
  logic [AddrWidth-1:0] araddr;
  logic [IdWidth-1:0] arid;
  logic [7:0] arlen;
  logic [2:0] arsize;
  logic [1:0] arburst;

  logic rvalid;
  logic rready;
  logic [1:0] rresp;
  logic [DataWidth-1:0] rdata;
  logic rlast;
  logic [IdWidth-1:0] rid;

  modport master (
    output awvalid, awaddr, awid, awlen, awsize, awburst,
           wvalid, wdata, wstrb, wlast, bready,
           arvalid, araddr, arid, arlen, arsize, arburst, rready,
    input awready, wready, bvalid, bresp, bid,
          arready, rvalid, rresp, rdata, rlast, rid
  );
  modport slave (
    input awvalid, awaddr, awid, awlen, awsize, awburst,
          wvalid, wdata, wstrb, wlast, bready,
          arvalid, araddr, arid, arlen, arsize, arburst, rready,
    output awready, wready, bvalid, bresp, bid,
           arready, rvalid, rresp, rdata, rlast, rid
  );
  modport monitor (
    input awvalid, awready, awaddr, awid, awlen, awsize, awburst,
          wvalid, wready, wdata, wstrb, wlast,
          bvalid, bready, bresp, bid,
          arvalid, arready, araddr, arid, arlen, arsize, arburst,
          rvalid, rready, rresp, rdata, rlast, rid
  );
endinterface
/* verilator lint_on DECLFILENAME */
