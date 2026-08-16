// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 最小 CoreBus CLINT。
//
// 提供每周期自增的 64 位 mtime，并通过两个相邻 32 位地址读取低、高半字。
// 当前不产生中断且 mtime 只读；仅接受对齐字读取；内部只保留一笔响应，
// 响应被上游接收前不得覆盖。
`include "common/assertions.svh"

module corebus_clint
  import riscv_bus_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter logic [AddrWidth-1:0] MtimeAddr = 32'h0200_bff8
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // CoreBus 从接口
  core_bus_if.slave core_bus
);

  //////////////////////
  // 计时器与响应状态 //
  //////////////////////

  logic [63:0] mtime_q;
  logic rsp_valid_q;
  logic [DataWidth-1:0] rsp_rdata_q;
  logic rsp_error_q;
  logic mtime_addr_hit;
  logic unused_write_payload;

  assign mtime_addr_hit = (core_bus.req_payload.addr == MtimeAddr) ||
      (core_bus.req_payload.addr == (MtimeAddr + AddrWidth'(4)));
  assign unused_write_payload = ^{core_bus.req_payload.wdata, core_bus.req_payload.wstrb};

  assign core_bus.req_ready = !rsp_valid_q;
  assign core_bus.rsp_payload.rdata = rsp_rdata_q;
  assign core_bus.rsp_payload.error = rsp_error_q;
  assign core_bus.rsp_valid = rsp_valid_q;

  /////////////////////////////
  // 计时与 CoreBus 事务处理 //
  /////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mtime_q <= 64'b0;
      rsp_valid_q <= 1'b0;
      rsp_rdata_q <= '0;
      rsp_error_q <= 1'b0;
    end else begin
      mtime_q <= mtime_q + 64'd1;

      if (rsp_valid_q && core_bus.rsp_ready) rsp_valid_q <= 1'b0;

      if (core_bus.req_valid && core_bus.req_ready) begin
        rsp_valid_q <= 1'b1;
        rsp_error_q <= core_bus.req_payload.write ||
            (core_bus.req_payload.size != CORE_BUS_SIZE_WORD) || !mtime_addr_hit;
        if (!core_bus.req_payload.write && (core_bus.req_payload.size == CORE_BUS_SIZE_WORD) &&
            mtime_addr_hit)
          rsp_rdata_q <= (core_bus.req_payload.addr == MtimeAddr) ? mtime_q[31:0] : mtime_q[63:32];
        else rsp_rdata_q <= '0;
      end
    end
  end

  //////////////
  // 参数断言 //
  //////////////

  `ASSERT_INIT(ClintDataWidthSupported, DataWidth == 32)
  `ASSERT_INIT(ClintAddressWidthValid, AddrWidth > 0)
  `ASSERT_INIT(ClintCoreBusAddrWidth, $bits(core_bus.req_payload.addr) == AddrWidth)
  `ASSERT_INIT(ClintCoreBusDataWidth, $bits(core_bus.req_payload.wdata) == DataWidth)

endmodule
