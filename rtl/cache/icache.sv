// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 临时指令 Cache 适配器。
//
// 将 CoreBus 取指请求直接转换为单拍 AXI4 读事务。
// 当前不包含缓存存储；只接受对齐的字读取；AXI 响应必须为单拍且 ID 匹配；
// 本模块不得驱动任何 AXI 写通道。
`include "common/assertions.svh"

module icache
  import riscv_bus_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = ICACHE_AXI_ID
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // CoreBus 与 AXI4
  core_bus_if.slave core_bus,
  axi4_if.master axi
);

  ///////////////////////////
  // CoreBus/AXI4 组合适配 //
  ///////////////////////////

  logic unused_axi_write_resp;

  assign unused_axi_write_resp = ^{axi.awready, axi.wready, axi.bvalid, axi.b_payload};

  always_comb begin
    axi.awvalid = 1'b0;
    axi.aw_payload = '0;
    axi.wvalid = 1'b0;
    axi.w_payload = '0;
    axi.bready = 1'b0;
    axi.arvalid = core_bus.req_valid;
    axi.ar_payload.addr = core_bus.req_payload.addr;
    axi.ar_payload.id = IdWidth'(AxiId);
    axi.ar_payload.len = 8'd0;
    axi.ar_payload.size = 3'd2;
    axi.ar_payload.burst = AXI4_BURST_INCR;
    axi.rready = core_bus.rsp_ready;

    core_bus.req_ready = axi.arready;
    core_bus.rsp_payload.rdata = axi.r_payload.data;
    core_bus.rsp_payload.error = (axi.r_payload.resp != AXI4_RESP_OKAY) || !axi.r_payload.last ||
        (axi.r_payload.id != IdWidth'(AxiId));
    core_bus.rsp_valid = axi.rvalid;
  end

  ////////////////////
  // 协议与参数断言 //
  ////////////////////

  `ASSERT(
      ICacheCoreBusReadOnly,
      core_bus.req_valid |-> !core_bus.req_payload.write && (core_bus.req_payload.size == CORE_BUS_SIZE_WORD) && (core_bus.req_payload.addr[1:0] == 2'b00) && (core_bus.req_payload.wdata == '0) && (core_bus.req_payload.wstrb == '0),
      clk_i, !rst_ni, "ICache only accepts aligned word reads.")

  `ASSERT_INIT(ICacheCoreBusAddrWidth, $bits(core_bus.req_payload.addr) == AddrWidth)
  `ASSERT_INIT(ICacheCoreBusDataWidth, $bits(core_bus.req_payload.wdata) == DataWidth)
  `ASSERT_INIT(ICacheAxiAddrWidth, $bits(axi.aw_payload.addr) == AddrWidth)
  `ASSERT_INIT(ICacheAxiDataWidth, $bits(axi.w_payload.data) == DataWidth)
  `ASSERT_INIT(ICacheAxiIdWidth, $bits(axi.aw_payload.id) == IdWidth)
  `ASSERT_INIT(ICacheAxiIdFits, (AxiId >> IdWidth) == 0)
  `ASSERT_INIT(ICacheAddressAndIdWidthsValid, AddrWidth > 0 && IdWidth > 0)
  `ASSERT_INIT(ICacheDataWidthValid,
               DataWidth >= 8 && (DataWidth % 8) == 0 && (DataWidth & (DataWidth - 1)) == 0)

endmodule
