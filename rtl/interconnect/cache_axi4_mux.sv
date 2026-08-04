// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Merge the placeholder caches onto the public AXI4 master.  DCache owns all
// write channels; read addresses use fixed DCache priority.  Read responses
// use independent fall-through FIFOs, so either cache may apply backpressure
// without blocking responses for the other AXI ID.
`include "common/assertions.svh"

import riscv_core_pkg::*;

module cache_axi4_mux #(
  // The counters below limit end-to-end outstanding reads as well as sizing
  // the response FIFOs.  Two ICache entries preserve same-cycle response/next
  // request throughput for the default one-outstanding fetch frontend.
  parameter int unsigned ICacheReadDepth = 2,
  parameter int unsigned DCacheReadDepth = 1,
  parameter int unsigned ICacheReadCountW =
      (ICacheReadDepth > 1) ? $clog2(ICacheReadDepth + 1) : 1,
  parameter int unsigned DCacheReadCountW =
      (DCacheReadDepth > 1) ? $clog2(DCacheReadDepth + 1) : 1
) (
  input logic clk_i,
  input logic rst_ni,

  input  axi4_req_t  icache_req_i,
  output axi4_resp_t icache_resp_o,
  input  axi4_req_t  dcache_req_i,
  output axi4_resp_t dcache_resp_o,

  output axi4_req_t  master_req_o,
  input  axi4_resp_t master_resp_i
);

  typedef struct packed {
    logic [1:0] rresp;
    word_t rdata;
    logic rlast;
    axi4_id_t rid;
  } read_response_t;

  logic ar_locked_q;
  logic ar_owner_dcache_q;
  logic select_dcache;
  logic master_ar_fire;
  logic icache_ar_fire;
  logic dcache_ar_fire;
  logic icache_ar_credit;
  logic dcache_ar_credit;

  logic [ICacheReadCountW-1:0] icache_read_count_q;
  logic [DCacheReadCountW-1:0] dcache_read_count_q;

  read_response_t master_read_response;
  read_response_t icache_read_response;
  read_response_t dcache_read_response;
  logic icache_read_input_ready;
  logic dcache_read_input_ready;
  logic icache_read_valid;
  logic dcache_read_valid;
  logic icache_read_fire;
  logic dcache_read_fire;

  logic unused_icache_write_payload;

  assign icache_ar_credit =
      icache_read_count_q < ICacheReadCountW'(ICacheReadDepth);
  assign dcache_ar_credit =
      dcache_read_count_q < DCacheReadCountW'(DCacheReadDepth);
  assign select_dcache = ar_locked_q ? ar_owner_dcache_q :
      (dcache_req_i.arvalid && dcache_ar_credit);

  assign master_read_response = '{
    rresp: master_resp_i.rresp,
    rdata: master_resp_i.rdata,
    rlast: master_resp_i.rlast,
    rid: master_resp_i.rid
  };
  assign icache_read_fire = icache_read_valid && icache_req_i.rready;
  assign dcache_read_fire = dcache_read_valid && dcache_req_i.rready;

  assign unused_icache_write_payload = ^{icache_req_i.awaddr, icache_req_i.awid,
                                        icache_req_i.awlen, icache_req_i.awsize,
                                        icache_req_i.awburst, icache_req_i.wdata,
                                        icache_req_i.wstrb, icache_req_i.wlast};

  always_comb begin
    master_req_o = '0;
    icache_resp_o = '0;
    dcache_resp_o = '0;

    // Only DCache writes memory.
    master_req_o.awvalid = dcache_req_i.awvalid;
    master_req_o.awaddr = dcache_req_i.awaddr;
    master_req_o.awid = dcache_req_i.awid;
    master_req_o.awlen = dcache_req_i.awlen;
    master_req_o.awsize = dcache_req_i.awsize;
    master_req_o.awburst = dcache_req_i.awburst;
    dcache_resp_o.awready = master_resp_i.awready;

    master_req_o.wvalid = dcache_req_i.wvalid;
    master_req_o.wdata = dcache_req_i.wdata;
    master_req_o.wstrb = dcache_req_i.wstrb;
    master_req_o.wlast = dcache_req_i.wlast;
    dcache_resp_o.wready = master_resp_i.wready;

    master_req_o.bready = dcache_req_i.bready;
    dcache_resp_o.bvalid = master_resp_i.bvalid;
    dcache_resp_o.bresp = master_resp_i.bresp;
    dcache_resp_o.bid = master_resp_i.bid;

    // Every accepted read is covered by one response FIFO credit, so a legal
    // AXI response can always be accepted.  This also removes the combinational
    // RVALID/RID-to-RREADY path at the public master interface.
    master_req_o.rready = rst_ni;

    // A data read wins only the contested AR cycle.  Writes use independent
    // AXI channels and therefore never block instruction reads here.
    if (select_dcache) begin
      master_req_o.arvalid = dcache_req_i.arvalid && dcache_ar_credit;
      master_req_o.araddr = dcache_req_i.araddr;
      master_req_o.arid = dcache_req_i.arid;
      master_req_o.arlen = dcache_req_i.arlen;
      master_req_o.arsize = dcache_req_i.arsize;
      master_req_o.arburst = dcache_req_i.arburst;
      dcache_resp_o.arready = master_resp_i.arready && dcache_ar_credit;
    end else begin
      master_req_o.arvalid = icache_req_i.arvalid && icache_ar_credit;
      master_req_o.araddr = icache_req_i.araddr;
      master_req_o.arid = icache_req_i.arid;
      master_req_o.arlen = icache_req_i.arlen;
      master_req_o.arsize = icache_req_i.arsize;
      master_req_o.arburst = icache_req_i.arburst;
      icache_resp_o.arready = master_resp_i.arready && icache_ar_credit;
    end

    // Empty response FIFOs are fall-through, retaining the original
    // zero-added-latency response path.  Backpressured responses are captured
    // locally and can then drain independently for the two AXI IDs.
    icache_resp_o.rvalid = icache_read_valid;
    icache_resp_o.rdata = icache_read_response.rdata;
    icache_resp_o.rresp = icache_read_response.rresp;
    icache_resp_o.rlast = icache_read_response.rlast;
    icache_resp_o.rid = icache_read_response.rid;
    dcache_resp_o.rvalid = dcache_read_valid;
    dcache_resp_o.rdata = dcache_read_response.rdata;
    dcache_resp_o.rresp = dcache_read_response.rresp;
    dcache_resp_o.rlast = dcache_read_response.rlast;
    dcache_resp_o.rid = dcache_read_response.rid;
  end

  assign master_ar_fire = master_req_o.arvalid && master_resp_i.arready;
  assign icache_ar_fire = master_ar_fire && !select_dcache;
  assign dcache_ar_fire = master_ar_fire && select_dcache;

  stream_fifo #(
    .Depth(ICacheReadDepth),
    .FallThrough(1'b1),
    .SameCycleRW(1'b1),
    .T(read_response_t)
  ) u_icache_read_response_fifo (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .usage_o(  /* unused */),
    .data_i(master_read_response),
    .valid_i(rst_ni && master_resp_i.rvalid &&
        (master_resp_i.rid == ICACHE_AXI_ID)),
    .ready_o(icache_read_input_ready),
    .data_o(icache_read_response),
    .valid_o(icache_read_valid),
    .ready_i(icache_req_i.rready)
  );

  stream_fifo #(
    .Depth(DCacheReadDepth),
    .FallThrough(1'b1),
    .SameCycleRW(1'b1),
    .T(read_response_t)
  ) u_dcache_read_response_fifo (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .usage_o(  /* unused */),
    .data_i(master_read_response),
    .valid_i(rst_ni && master_resp_i.rvalid &&
        (master_resp_i.rid == DCACHE_AXI_ID)),
    .ready_o(dcache_read_input_ready),
    .data_o(dcache_read_response),
    .valid_o(dcache_read_valid),
    .ready_i(dcache_req_i.rready)
  );

  // Preserve the selected source while AXI backpressures AR.  No register is
  // inserted into the accepted path, so an immediately ready request remains
  // a purely combinational transfer.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_locked_q <= 1'b0;
      ar_owner_dcache_q <= 1'b0;
    end else if (ar_locked_q) begin
      if (master_ar_fire) ar_locked_q <= 1'b0;
    end else if (master_req_o.arvalid && !master_resp_i.arready) begin
      ar_locked_q <= 1'b1;
      ar_owner_dcache_q <= select_dcache;
    end
  end

  // Credits cover the complete path from an accepted AR through delivery to
  // the selected cache.  Consequently a full response FIFO cannot have
  // another legal response for the same ID waiting at the AXI interface.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      icache_read_count_q <= '0;
      dcache_read_count_q <= '0;
    end else begin
      unique case ({icache_ar_fire, icache_read_fire})
        2'b10: icache_read_count_q <= icache_read_count_q +
            ICacheReadCountW'(1);
        2'b01: icache_read_count_q <= icache_read_count_q -
            ICacheReadCountW'(1);
        default: ;
      endcase
      unique case ({dcache_ar_fire, dcache_read_fire})
        2'b10: dcache_read_count_q <= dcache_read_count_q +
            DCacheReadCountW'(1);
        2'b01: dcache_read_count_q <= dcache_read_count_q -
            DCacheReadCountW'(1);
        default: ;
      endcase
    end
  end

  `ASSERT_INIT(ICacheReadDepthValid, ICacheReadDepth > 0,
               "ICache read response depth must be greater than zero.")
  `ASSERT_INIT(DCacheReadDepthValid, DCacheReadDepth > 0,
               "DCache read response depth must be greater than zero.")
  `ASSERT(ICacheNeverWrites,
          !icache_req_i.awvalid && !icache_req_i.wvalid && !icache_req_i.bready,
          clk_i, !rst_ni, "ICache must not drive AXI write channels.")
  `ASSERT(CacheReadIdKnown,
          master_resp_i.rvalid |->
              (master_resp_i.rid == ICACHE_AXI_ID) ||
              (master_resp_i.rid == DCACHE_AXI_ID),
          clk_i, !rst_ni, "AXI read response ID must identify a cache.")
  `ASSERT(ICacheReadResponseExpected,
          master_resp_i.rvalid && (master_resp_i.rid == ICACHE_AXI_ID) |->
              (icache_read_count_q != '0) || icache_ar_fire,
          clk_i, !rst_ni, "ICache read response must match an accepted request.")
  `ASSERT(DCacheReadResponseExpected,
          master_resp_i.rvalid && (master_resp_i.rid == DCACHE_AXI_ID) |->
              (dcache_read_count_q != '0) || dcache_ar_fire,
          clk_i, !rst_ni, "DCache read response must match an accepted request.")
  `ASSERT(ICacheReadResponseFits,
          master_resp_i.rvalid && (master_resp_i.rid == ICACHE_AXI_ID) |->
              icache_read_input_ready,
          clk_i, !rst_ni, "ICache read response FIFO must have space.")
  `ASSERT(DCacheReadResponseFits,
          master_resp_i.rvalid && (master_resp_i.rid == DCACHE_AXI_ID) |->
              dcache_read_input_ready,
          clk_i, !rst_ni, "DCache read response FIFO must have space.")
  `ASSERT(DCacheWriteId,
          master_resp_i.bvalid |-> (master_resp_i.bid == DCACHE_AXI_ID),
          clk_i, !rst_ni, "Only DCache may receive AXI write responses.")

endmodule
