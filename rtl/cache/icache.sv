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

  assign unused_axi_write_resp = ^{axi.awready, axi.wready,
                                   axi.bvalid, axi.bresp, axi.bid};

  always_comb begin
    axi.awvalid = 1'b0;
    axi.awaddr = '0;
    axi.awid = '0;
    axi.awlen = '0;
    axi.awsize = '0;
    axi.awburst = '0;
    axi.wvalid = 1'b0;
    axi.wdata = '0;
    axi.wstrb = '0;
    axi.wlast = 1'b0;
    axi.bready = 1'b0;
    axi.arvalid = core_bus.req_valid;
    axi.araddr = core_bus.addr;
    axi.arid = IdWidth'(AxiId);
    axi.arlen = 8'd0;
    axi.arsize = 3'd2;
    axi.arburst = AXI4_BURST_INCR;
    axi.rready = core_bus.rsp_ready;

    core_bus.req_ready = axi.arready;
    core_bus.rdata = axi.rdata;
    core_bus.error = (axi.rresp != AXI4_RESP_OKAY) ||
        !axi.rlast || (axi.rid != IdWidth'(AxiId));
    core_bus.rsp_valid = axi.rvalid;
  end

  ////////////////////
  // 协议与参数断言 //
  ////////////////////

  `ASSERT(ICacheCoreBusReadOnly,
          core_bus.req_valid |->
              !core_bus.write && (core_bus.size == CORE_BUS_SIZE_WORD) &&
              (core_bus.addr[1:0] == 2'b00) &&
              (core_bus.wdata == '0) && (core_bus.wstrb == '0),
          clk_i, !rst_ni, "ICache only accepts aligned word reads.")

  `ASSERT_INIT(ICacheCoreBusAddrWidth,
               $bits(core_bus.addr) == AddrWidth)
  `ASSERT_INIT(ICacheCoreBusDataWidth,
               $bits(core_bus.wdata) == DataWidth)
  `ASSERT_INIT(ICacheAxiAddrWidth, $bits(axi.awaddr) == AddrWidth)
  `ASSERT_INIT(ICacheAxiDataWidth, $bits(axi.wdata) == DataWidth)
  `ASSERT_INIT(ICacheAxiIdWidth, $bits(axi.awid) == IdWidth)
  `ASSERT_INIT(ICacheAxiIdFits, (AxiId >> IdWidth) == 0)
  `ASSERT_INIT(ICacheAddressAndIdWidthsValid,
               AddrWidth > 0 && IdWidth > 0)
  `ASSERT_INIT(ICacheDataWidthValid,
               DataWidth >= 8 && (DataWidth % 8) == 0 &&
                   (DataWidth & (DataWidth - 1)) == 0)

endmodule
