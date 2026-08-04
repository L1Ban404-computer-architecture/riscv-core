// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef AXI4_BUS_TYPES_SVH
`define AXI4_BUS_TYPES_SVH

`include "riscv_core_config.svh"

typedef logic [3:0] axi4_id_t;

// Signals driven by an AXI4 master.  Widths intentionally match the public
// ysyx_25080230 interface; the placeholder caches only issue single-beat
// transactions, while the type keeps the complete exposed channel payload.
typedef struct packed {
  logic awvalid;
  word_t awaddr;
  axi4_id_t awid;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [1:0] awburst;

  logic wvalid;
  word_t wdata;
  byte_en_t wstrb;
  logic wlast;

  logic bready;

  logic arvalid;
  word_t araddr;
  axi4_id_t arid;
  logic [7:0] arlen;
  logic [2:0] arsize;
  logic [1:0] arburst;

  logic rready;
} axi4_req_t;

// Signals returned by an AXI4 slave.
typedef struct packed {
  logic awready;
  logic wready;

  logic bvalid;
  logic [1:0] bresp;
  axi4_id_t bid;

  logic arready;

  logic rvalid;
  logic [1:0] rresp;
  word_t rdata;
  logic rlast;
  axi4_id_t rid;
} axi4_resp_t;

localparam axi4_id_t ICACHE_AXI_ID = 4'd0;
localparam axi4_id_t DCACHE_AXI_ID = 4'd1;
localparam logic [1:0] AXI4_RESP_OKAY = 2'b00;
localparam logic [1:0] AXI4_BURST_INCR = 2'b01;

`endif
