// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// core_bus 取指主设备。空闲或本拍请求已被接受时采样 issue_i 和字地址，否则保持 valid 和地址。
// 写出对齐字读。求解器字地址低两位补 0、高位补 0，成为 icache 地址。
module fv_cpu_fetch
  import riscv_bus_pkg::*;
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = ICacheAddrWidth,
  parameter int unsigned SolverAddrWidth = 12
) (
  input logic clk_i,
  input logic rst_ni,

  input logic issue_i,
  input logic [SolverAddrWidth-1:2] addr_word_i,
  input logic rsp_ready_i,

  core_bus_if.master core_bus
);

  logic req_valid_q;
  logic [AddrWidth-1:0] req_addr_q;

  assign core_bus.req_valid = req_valid_q;
  assign core_bus.req_payload = '{
    addr: req_addr_q,
    write: 1'b0,
    size: CORE_BUS_SIZE_WORD,
    wdata: '0
  };
  assign core_bus.rsp_ready = rsp_ready_i;

  initial begin
    req_valid_q = 1'b0;
    req_addr_q = '0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_valid_q <= 1'b0;
      req_addr_q <= '0;
    end else if (!req_valid_q || core_bus.req_ready) begin
      req_valid_q <= issue_i;
      req_addr_q <= AddrWidth'({addr_word_i, 2'b00});
    end
  end

endmodule
