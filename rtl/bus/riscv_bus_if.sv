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
  parameter int unsigned DataWidth = 32
);
  // write 区分读写；size 为 AxSIZE 编码。写字节掩码由下游用 size 与地址低位推导。
  typedef struct packed {
    logic [AddrWidth-1:0] addr;
    logic write;
    riscv_bus_pkg::core_bus_size_e size;
    logic [DataWidth-1:0] wdata;
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
  logic req_fire;
  logic rsp_fire;

  // fire 由握手派生，所有 modport 只读，模块不得驱动。
  assign req_fire = req_valid && req_ready;
  assign rsp_fire = rsp_valid && rsp_ready;

  modport master(
      output req_payload, req_valid, rsp_ready, input req_ready, rsp_payload, rsp_valid, req_fire,
          rsp_fire
  );
  modport slave(
      input req_payload, req_valid, rsp_ready, req_fire, rsp_fire, output req_ready, rsp_payload,
          rsp_valid
  );
  // 请求接收与响应发送可以分属不同模块。输出与 slave 重叠，同一实例只连接其中一组驱动。
  modport req_slave(input req_payload, req_valid, req_fire, output req_ready);
  modport rsp_source(input rsp_ready, rsp_fire, output rsp_payload, rsp_valid);
  modport monitor(
      input req_payload, req_valid, req_ready, req_fire, rsp_payload, rsp_valid, rsp_ready, rsp_fire
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
  logic aw_fire;

  logic wvalid;
  logic wready;
  logic w_fire;

  logic bvalid;
  logic bready;
  logic b_fire;

  logic arvalid;
  logic arready;
  logic ar_fire;

  logic rvalid;
  logic rready;
  logic r_fire;

  // 各通道 fire 由握手派生，所有 modport 只读，模块不得驱动。
  assign aw_fire = awvalid && awready;
  assign w_fire = wvalid && wready;
  assign b_fire = bvalid && bready;
  assign ar_fire = arvalid && arready;
  assign r_fire = rvalid && rready;

  modport master(
      output awvalid, aw_payload, wvalid, w_payload, bready, arvalid, ar_payload, rready,
      input awready, wready, bvalid, b_payload, arready, rvalid, r_payload, aw_fire, w_fire, b_fire,
          ar_fire, r_fire
  );
  modport slave(
      input awvalid, aw_payload, wvalid, w_payload, bready, arvalid, ar_payload, rready, aw_fire,
          w_fire, b_fire, ar_fire, r_fire,
      output awready, wready, bvalid, b_payload, arready, rvalid, r_payload
  );
  modport monitor(
      input awvalid, awready, aw_fire, aw_payload, wvalid, wready, w_fire, w_payload, bvalid,
          bready, b_fire, b_payload, arvalid, arready, ar_fire, ar_payload, rvalid, rready, r_fire,
          r_payload
  );
endinterface
/* verilator lint_on DECLFILENAME */
