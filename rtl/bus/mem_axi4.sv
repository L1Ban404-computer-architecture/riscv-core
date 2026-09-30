// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单笔在途 CoreBus 到 AXI4 适配器。
//
// 该模块直接使用尚未完成握手的 CoreBus 请求 payload；除写地址与写数据的
// 独立握手标志和最小状态机外，不保存请求或响应数据。
`include "common/assertions.svh"

module mem_axi4
  import riscv_bus_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = MEM_AXI_ID,
  localparam int unsigned StrbWidth = DataWidth / 8
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // CoreBus 与 AXI4
  core_bus_if.slave core_bus,
  axi4_if.master axi
);

  ////////////////////////
  // 事务状态与握手事件 //
  ////////////////////////

  typedef enum logic [1:0] {
    StateIdle,
    StateReadResponse,
    StateWriteResponse
  } state_e;

  state_e state_q;
  logic aw_sent_q;
  logic w_sent_q;
  logic read_request;
  logic write_request;
  logic write_request_complete;
  logic active_read_response;
  logic active_write_response;
  logic [2:0] axi_size;
  logic [StrbWidth-1:0] write_strb;

  // CoreBus 不携带 wstrb；写掩码由 size 与地址低位还原，并保留原始 byte 地址，
  // 以便 UART 等按 paddr 低位译码的 MMIO 正确。
  function automatic logic [StrbWidth-1:0] wstrb_from_size_addr(
      input core_bus_size_e size, input logic [1:0] addr_offset);
    unique case (size)
      CORE_BUS_SIZE_BYTE: return StrbWidth'(4'b0001 << addr_offset);
      CORE_BUS_SIZE_HALF: return StrbWidth'(4'b0011 << addr_offset);
      default: return '1;
    endcase
  endfunction

  assign axi_size = {1'b0, core_bus.req_payload.size};
  assign write_strb =
      wstrb_from_size_addr(core_bus.req_payload.size, core_bus.req_payload.addr[1:0]);
  assign read_request = (state_q == StateIdle) && !aw_sent_q && !w_sent_q &&
      core_bus.req_valid && !core_bus.req_payload.write;
  assign write_request =
      (state_q == StateIdle) && core_bus.req_valid && core_bus.req_payload.write;

  assign write_request_complete =
      write_request && (aw_sent_q || axi.aw_fire) && (w_sent_q || axi.w_fire);

  // 同拍 AXI 响应无需额外保存：请求握手期间直接让 CoreBus 响应通道可用。
  assign active_read_response = (state_q == StateReadResponse) || axi.ar_fire;
  assign active_write_response = (state_q == StateWriteResponse) || write_request_complete;

  ////////////////////////////
  // CoreBus 与 AXI4 通道适配 //
  ////////////////////////////

  always_comb begin
    axi.awvalid = write_request && !aw_sent_q;
    axi.aw_payload.addr = core_bus.req_payload.addr;
    axi.aw_payload.id = IdWidth'(AxiId);
    axi.aw_payload.len = 8'd0;
    axi.aw_payload.size = axi_size;
    axi.aw_payload.burst = AXI4_BURST_INCR;
    axi.wvalid = write_request && !w_sent_q;
    axi.w_payload.data = core_bus.req_payload.wdata;
    axi.w_payload.strb = write_strb;
    axi.w_payload.last = 1'b1;
    axi.bready = active_write_response && core_bus.rsp_ready;
    axi.arvalid = read_request;
    axi.ar_payload.addr = core_bus.req_payload.addr;
    axi.ar_payload.id = IdWidth'(AxiId);
    axi.ar_payload.len = 8'd0;
    axi.ar_payload.size = axi_size;
    axi.ar_payload.burst = AXI4_BURST_INCR;
    axi.rready = active_read_response && core_bus.rsp_ready;

    core_bus.req_ready = 1'b0;
    core_bus.rsp_valid = 1'b0;
    core_bus.rsp_payload = '0;
    if (state_q == StateIdle) begin
      core_bus.req_ready =
          core_bus.req_payload.write ? write_request_complete : axi.arready;
    end

    if (active_read_response) begin
      core_bus.rsp_valid = axi.rvalid;
      core_bus.rsp_payload.rdata = axi.r_payload.data;
      core_bus.rsp_payload.error = (axi.r_payload.resp != AXI4_RESP_OKAY) || !axi.r_payload.last ||
          (axi.r_payload.id != IdWidth'(AxiId));
    end else if (active_write_response) begin
      core_bus.rsp_valid = axi.bvalid;
      core_bus.rsp_payload.error = (axi.b_payload.resp != AXI4_RESP_OKAY) ||
          (axi.b_payload.id != IdWidth'(AxiId));
    end
  end

  //////////////////
  // 状态更新逻辑 //
  //////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StateIdle;
      aw_sent_q <= 1'b0;
      w_sent_q <= 1'b0;
    end else begin
      unique case (state_q)
        StateIdle: begin
          if (write_request) begin
            if (core_bus.req_fire) begin
              aw_sent_q <= 1'b0;
              w_sent_q <= 1'b0;
              if (!core_bus.rsp_fire) state_q <= StateWriteResponse;
            end else begin
              if (axi.aw_fire) aw_sent_q <= 1'b1;
              if (axi.w_fire) w_sent_q <= 1'b1;
            end
          end else if (core_bus.req_fire && !core_bus.rsp_fire) begin
            state_q <= StateReadResponse;
          end
        end

        StateReadResponse, StateWriteResponse: begin
          if (core_bus.rsp_fire) state_q <= StateIdle;
        end

        default: begin
          state_q <= StateIdle;
          aw_sent_q <= 1'b0;
          w_sent_q <= 1'b0;
        end
      endcase
    end
  end

  //////////////////
  // 协议与参数断言 //
  //////////////////

  `ASSERT_STABLE(MemAxiCoreBusRequestStable, core_bus.req_valid, core_bus.req_ready,
                 core_bus.req_payload, '0, clk_i, !rst_ni)
  `ASSERT_STABLE(MemAxiCoreBusResponseStable, core_bus.rsp_valid, core_bus.rsp_ready,
                 core_bus.rsp_payload, '0, clk_i, !rst_ni)
  `ASSERT_STABLE(MemAxiAwStable, axi.awvalid, axi.awready, axi.aw_payload, '0,
                 clk_i, !rst_ni)
  `ASSERT_STABLE(MemAxiWStable, axi.wvalid, axi.wready, axi.w_payload, '0,
                 clk_i, !rst_ni)
  `ASSERT_STABLE(MemAxiArStable, axi.arvalid, axi.arready, axi.ar_payload, '0,
                 clk_i, !rst_ni)
  `ASSERT(MemAxiSingleBeatRead,
          axi.rvalid && active_read_response |-> axi.r_payload.last, clk_i, !rst_ni,
          "CoreBus adapter only accepts single-beat AXI reads.")
  `ASSERT(MemAxiReadId,
          axi.rvalid && active_read_response |-> (axi.r_payload.id == IdWidth'(AxiId)), clk_i,
          !rst_ni, "AXI read response ID must match the CoreBus adapter.")
  `ASSERT(MemAxiWriteId,
          axi.bvalid && active_write_response |-> (axi.b_payload.id == IdWidth'(AxiId)), clk_i,
          !rst_ni, "AXI write response ID must match the CoreBus adapter.")

  `ASSERT_INIT(MemAxiAddrWidth, $bits(core_bus.req_payload.addr) == AddrWidth)
  `ASSERT_INIT(MemAxiDataWidth, $bits(core_bus.req_payload.wdata) == DataWidth)
  `ASSERT_INIT(MemAxiAxiAddrWidth, $bits(axi.aw_payload.addr) == AddrWidth)
  `ASSERT_INIT(MemAxiAxiDataWidth, $bits(axi.w_payload.data) == DataWidth)
  `ASSERT_INIT(MemAxiIdWidth, $bits(axi.aw_payload.id) == IdWidth)
  `ASSERT_INIT(MemAxiIdFits, (AxiId >> IdWidth) == 0)
  `ASSERT_INIT(MemAxiAddressAndIdWidthsValid, AddrWidth > 0 && IdWidth > 0)
  `ASSERT_INIT(MemAxiDataWidthValid,
               DataWidth >= 8 && (DataWidth % 8) == 0 && (DataWidth & (DataWidth - 1)) == 0)

endmodule
