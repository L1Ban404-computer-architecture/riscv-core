// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Placeholder instruction cache.  It deliberately contains no cache storage:
// CoreBus reads pass directly to single-beat AXI4 reads.
`include "common/assertions.svh"

import riscv_core_pkg::*;

module icache (
  input logic clk_i,
  input logic rst_ni,

  input  core_bus_req_t  core_req_i,
  output core_bus_resp_t core_resp_o,

  output axi4_req_t  axi_req_o,
  input  axi4_resp_t axi_resp_i
);

  logic unused_axi_write_resp;

  assign unused_axi_write_resp = ^{axi_resp_i.awready, axi_resp_i.wready,
                                   axi_resp_i.bvalid, axi_resp_i.bresp,
                                   axi_resp_i.bid};

  always_comb begin
    axi_req_o = '0;
    axi_req_o.arvalid = core_req_i.req_valid;
    axi_req_o.araddr = core_req_i.addr;
    axi_req_o.arid = ICACHE_AXI_ID;
    axi_req_o.arlen = 8'd0;
    axi_req_o.arsize = 3'd2;
    axi_req_o.arburst = AXI4_BURST_INCR;
    axi_req_o.rready = core_req_i.rsp_ready;

    core_resp_o = '0;
    core_resp_o.req_ready = axi_resp_i.arready;
    core_resp_o.rdata = axi_resp_i.rdata;
    core_resp_o.error = (axi_resp_i.rresp != AXI4_RESP_OKAY) ||
        !axi_resp_i.rlast || (axi_resp_i.rid != ICACHE_AXI_ID);
    core_resp_o.rsp_valid = axi_resp_i.rvalid;
  end

  `ASSERT(ICacheCoreBusReadOnly,
          core_req_i.req_valid |->
              !core_req_i.write && (core_req_i.size == MEM_SIZE_WORD) &&
              (core_req_i.addr[1:0] == 2'b00) &&
              (core_req_i.wdata == '0) && (core_req_i.wstrb == '0),
          clk_i, !rst_ni, "ICache only accepts aligned word reads.")

endmodule
