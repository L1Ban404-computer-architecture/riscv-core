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
  typedef struct packed {
    logic [AddrWidth-1:0] addr;
    logic write;
    riscv_bus_pkg::core_bus_size_e size;
    logic [DataWidth-1:0] wdata;
    logic [StrbWidth-1:0] wstrb;
  } req_payload_t;

  typedef struct packed {
    logic [DataWidth-1:0] rdata;
    logic error;
  } rsp_payload_t;

  req_payload_t req_payload;
  rsp_payload_t rsp_payload;
  logic req_valid;
  logic req_ready;
  logic rsp_valid;
  logic rsp_ready;

  modport master (
    output req_payload, req_valid, rsp_ready,
    input req_ready, rsp_payload, rsp_valid
  );
  modport slave (
    input req_payload, req_valid, rsp_ready,
    output req_ready, rsp_payload, rsp_valid
  );
  modport monitor (
    input req_payload, req_valid, req_ready,
          rsp_payload, rsp_valid, rsp_ready
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
  typedef struct packed {
    logic [AddrWidth-1:0] addr;
    logic [IdWidth-1:0] id;
    logic [7:0] len;
    logic [2:0] size;
    logic [1:0] burst;
  } aw_payload_t;

  typedef struct packed {
    logic [DataWidth-1:0] data;
    logic [StrbWidth-1:0] strb;
    logic last;
  } w_payload_t;

  typedef struct packed {
    logic [1:0] resp;
    logic [IdWidth-1:0] id;
  } b_payload_t;

  typedef struct packed {
    logic [AddrWidth-1:0] addr;
    logic [IdWidth-1:0] id;
    logic [7:0] len;
    logic [2:0] size;
    logic [1:0] burst;
  } ar_payload_t;

  typedef struct packed {
    logic [1:0] resp;
    logic [DataWidth-1:0] data;
    logic last;
    logic [IdWidth-1:0] id;
  } r_payload_t;

  aw_payload_t aw_payload;
  w_payload_t w_payload;
  b_payload_t b_payload;
  ar_payload_t ar_payload;
  r_payload_t r_payload;

  logic awvalid;
  logic awready;

  logic wvalid;
  logic wready;

  logic bvalid;
  logic bready;

  logic arvalid;
  logic arready;

  logic rvalid;
  logic rready;

  modport master (
    output awvalid, aw_payload,
           wvalid, w_payload, bready,
           arvalid, ar_payload, rready,
    input awready, wready, bvalid, b_payload,
          arready, rvalid, r_payload
  );
  modport slave (
    input awvalid, aw_payload,
          wvalid, w_payload, bready,
          arvalid, ar_payload, rready,
    output awready, wready, bvalid, b_payload,
           arready, rvalid, r_payload
  );
  modport monitor (
    input awvalid, awready, aw_payload,
          wvalid, wready, w_payload,
          bvalid, bready, b_payload,
          arvalid, arready, ar_payload,
          rvalid, rready, r_payload
  );
endinterface
/* verilator lint_on DECLFILENAME */
