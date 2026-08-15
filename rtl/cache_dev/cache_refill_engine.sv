// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 阻塞式 AXI4 写回与回填引擎。
//
// 可选写回脏牺牲行，随后以 AXI4 burst 读取缺失行，并返回完整缓存行和错误状态。
// 任一时刻只处理一笔替换；写回与回填复用同一缓存行缓冲区；各 AXI 通道
// 必须满足反压保持规则；只读配置不得驱动写通道。
`include "common/assertions.svh"

module cache_refill_engine
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
  import cache_pkg::*;
#(
  parameter int unsigned AddrWidth = XLen,
  parameter int unsigned DataWidth = XLen,
  parameter int unsigned IdWidth = 4,
  parameter bit ReadOnly = CacheDefaultReadOnly,
  parameter int unsigned BlockBytes = CacheDefaultBlockBytes,
  parameter int unsigned AxiId = DCACHE_AXI_ID,
  localparam int unsigned BlockOffsetW = $clog2(BlockBytes),
  localparam int unsigned BlockAddrW = XLen - BlockOffsetW,
  localparam int unsigned LineBits = BlockBytes * ByteW,
  localparam int unsigned LineBeats = BlockBytes / StrbW,
  localparam int unsigned BeatIndexW =
      (LineBeats > 1) ? $clog2(LineBeats) : 1
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 回填事务与 AXI4
  cache_refill_req_if.consumer refill_req,
  cache_refill_rsp_if.producer refill_rsp,
  axi4_if.master axi
);

  ////////////////////////////////
  // 状态、缓存行缓冲与握手事件 //
  ////////////////////////////////

  typedef enum logic [2:0] {
    StateIdle,
    StateWriteAddress,
    StateWriteData,
    StateWriteResponse,
    StateReadAddress,
    StateReadData,
    StateResponse
  } state_e;

  state_e state_q;
  logic [BlockAddrW-1:0] refill_block_addr_q;
  logic [BlockAddrW-1:0] writeback_block_addr_q;
  logic [LineBits-1:0] line_buffer_q;
  logic [BeatIndexW-1:0] beat_index_q;
  logic error_q;

  logic request_fire;
  logic response_fire;
  logic aw_fire;
  logic w_fire;
  logic b_fire;
  logic ar_fire;
  logic r_fire;
  logic expected_last;
  logic read_beat_error;
  logic write_response_error;
  logic request_writeback;

  ////////////////////////
  // 地址转换与请求属性 //
  ////////////////////////

  function automatic word_t block_byte_address(
    input logic [BlockAddrW-1:0] block_addr
  );
    word_t address;

    address = word_t'(block_addr);
    return address << BlockOffsetW;
  endfunction

  if (ReadOnly) begin : gen_no_writeback_request
    assign request_writeback = 1'b0;
  end else begin : gen_writeback_request
    assign request_writeback = refill_req.payload.writeback_valid;
  end

  assign request_fire = refill_req.valid && refill_req.ready;
  assign response_fire = refill_rsp.valid && refill_rsp.ready;
  assign aw_fire = axi.awvalid && axi.awready;
  assign w_fire = axi.wvalid && axi.wready;
  assign b_fire = axi.bvalid && axi.bready;
  assign ar_fire = axi.arvalid && axi.arready;
  assign r_fire = axi.rvalid && axi.rready;
  assign expected_last = beat_index_q == BeatIndexW'(LineBeats - 1);
  assign write_response_error =
      (axi.bid != IdWidth'(AxiId)) || (axi.bresp != AXI4_RESP_OKAY);
  assign read_beat_error = (axi.rid != IdWidth'(AxiId)) ||
      (axi.rresp != AXI4_RESP_OKAY) ||
      (axi.rlast != expected_last);

  ///////////////////
  // AXI4 通道驱动 //
  ///////////////////

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
    axi.arvalid = 1'b0;
    axi.araddr = '0;
    axi.arid = '0;
    axi.arlen = '0;
    axi.arsize = '0;
    axi.arburst = '0;
    axi.rready = 1'b0;
    refill_req.ready = state_q == StateIdle;
    refill_rsp.valid = state_q == StateResponse;
    refill_rsp.payload.data = line_buffer_q;
    refill_rsp.payload.error = error_q;

    unique case (state_q)
      StateWriteAddress: begin
        axi.awvalid = 1'b1;
        axi.awaddr = block_byte_address(writeback_block_addr_q);
        axi.awid = IdWidth'(AxiId);
        axi.awlen = 8'(LineBeats - 1);
        axi.awsize = 3'd2;
        axi.awburst = AXI4_BURST_INCR;
      end

      StateWriteData: begin
        axi.wvalid = 1'b1;
        axi.wdata =
            line_buffer_q[int'(beat_index_q) * XLen +: XLen];
        axi.wstrb = '1;
        axi.wlast = expected_last;
      end

      StateWriteResponse: begin
        axi.bready = 1'b1;
      end

      StateReadAddress: begin
        axi.arvalid = 1'b1;
        axi.araddr = block_byte_address(refill_block_addr_q);
        axi.arid = IdWidth'(AxiId);
        axi.arlen = 8'(LineBeats - 1);
        axi.arsize = 3'd2;
        axi.arburst = AXI4_BURST_INCR;
      end

      StateReadData: begin
        axi.rready = 1'b1;
      end

      default: ;
    endcase
  end

  //////////////////////
  // 写回与回填状态机 //
  //////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StateIdle;
      beat_index_q <= '0;
      error_q <= 1'b0;
    end else begin
      unique case (state_q)
        StateIdle: begin
          if (request_fire) begin
            refill_block_addr_q <= refill_req.payload.block_addr;
            writeback_block_addr_q <= refill_req.payload.writeback_block_addr;
            beat_index_q <= '0;
            error_q <= 1'b0;
            if (request_writeback) begin
              line_buffer_q <= refill_req.payload.writeback_data;
              state_q <= StateWriteAddress;
            end else begin
              state_q <= StateReadAddress;
            end
          end
        end

        StateWriteAddress: begin
          if (aw_fire) begin
            beat_index_q <= '0;
            state_q <= StateWriteData;
          end
        end

        StateWriteData: begin
          if (w_fire) begin
            if (expected_last) begin
              beat_index_q <= '0;
              state_q <= StateWriteResponse;
            end else begin
              beat_index_q <= beat_index_q + BeatIndexW'(1);
            end
          end
        end

        StateWriteResponse: begin
          if (b_fire) begin
            beat_index_q <= '0;
            if (write_response_error) begin
              error_q <= 1'b1;
              state_q <= StateResponse;
            end else begin
              state_q <= StateReadAddress;
            end
          end
        end

        StateReadAddress: begin
          if (ar_fire) begin
            beat_index_q <= '0;
            state_q <= StateReadData;
          end
        end

        StateReadData: begin
          if (r_fire) begin
            line_buffer_q[int'(beat_index_q) * XLen +: XLen] <=
                axi.rdata;
            error_q <= error_q || read_beat_error;
            if (axi.rlast || expected_last) begin
              state_q <= StateResponse;
            end else begin
              beat_index_q <= beat_index_q + BeatIndexW'(1);
            end
          end
        end

        StateResponse: begin
          if (response_fire) state_q <= StateIdle;
        end

        default: begin
          state_q <= StateIdle;
          beat_index_q <= '0;
          error_q <= 1'b0;
        end
      endcase
    end
  end

  ////////////////////
  // 协议与参数断言 //
  ////////////////////

  // verilog_format: off
  `ASSERT_INIT(CacheRefillLineBeatCountValid,
               (LineBeats > 0) && (LineBeats <= 256),
               "AXI4 bursts contain between one and 256 beats.")
  `ASSERT(CacheRefillRequestStable,
          refill_req.valid && !refill_req.ready |=>
              $stable({refill_req.valid, refill_req.payload}),
          clk_i, !rst_ni,
          "Refill request payload must remain stable while backpressured.")
  `ASSERT(CacheRefillResponseStable,
          refill_rsp.valid && !refill_rsp.ready |=>
              $stable({refill_rsp.valid, refill_rsp.payload}),
          clk_i, !rst_ni,
          "Refill response must remain stable while backpressured.")
  `ASSERT(CacheRefillAwStable,
          axi.awvalid && !axi.awready |=>
              $stable({axi.awvalid, axi.awaddr, axi.awid,
                       axi.awlen,
                       axi.awsize, axi.awburst}),
          clk_i, !rst_ni,
          "AXI write address payload must remain stable while backpressured.")
  `ASSERT(CacheRefillWStable,
          axi.wvalid && !axi.wready |=>
              $stable({axi.wvalid, axi.wdata, axi.wstrb,
                       axi.wlast}),
          clk_i, !rst_ni,
          "AXI write data payload must remain stable while backpressured.")
  `ASSERT(CacheRefillArStable,
          axi.arvalid && !axi.arready |=>
              $stable({axi.arvalid, axi.araddr, axi.arid,
                       axi.arlen,
                       axi.arsize, axi.arburst}),
          clk_i, !rst_ni,
          "AXI read address payload must remain stable while backpressured.")
  // verilog_format: on

  if (ReadOnly) begin : gen_read_only_assertions
    `ASSERT(CacheRefillEngineReadOnlyWriteback,
            refill_req.valid |-> !refill_req.payload.writeback_valid,
            clk_i, !rst_ni,
            "A read-only cache must never request a dirty writeback.")
    `ASSERT(CacheRefillEngineReadOnlyAxiWrite,
            !axi.awvalid && !axi.wvalid && !axi.bready,
            clk_i, !rst_ni,
            "A read-only refill engine must never drive AXI writes.")
  end

  `ASSERT_INIT(CacheRefillAddressWidthSupported, AddrWidth == XLen)
  `ASSERT_INIT(CacheRefillDataWidthSupported, DataWidth == XLen)
  `ASSERT_INIT(CacheRefillAddressAndIdWidthsValid,
               AddrWidth > 0 && IdWidth > 0)
  `ASSERT_INIT(CacheRefillDataWidthValid,
               DataWidth >= 8 && (DataWidth % 8) == 0 &&
                   (DataWidth & (DataWidth - 1)) == 0)
  `ASSERT_INIT(CacheRefillAxiAddrWidth,
               $bits(axi.awaddr) == AddrWidth)
  `ASSERT_INIT(CacheRefillAxiDataWidth,
               $bits(axi.wdata) == DataWidth)
  `ASSERT_INIT(CacheRefillAxiIdWidth, $bits(axi.awid) == IdWidth)
  `ASSERT_INIT(CacheRefillAxiIdFits, (AxiId >> IdWidth) == 0)
  `ASSERT_INIT(CacheRefillInterfaceWidths,
               $bits(refill_req.payload.block_addr) == BlockAddrW &&
                   $bits(refill_req.payload.writeback_data) == LineBits &&
                   $bits(refill_rsp.payload.data) == LineBits)

endmodule
