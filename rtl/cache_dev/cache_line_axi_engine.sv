// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 阻塞式缓存行 AXI4 搬运引擎。
//
// 对上层分别提供完整缓存行读取和写回事务，但内部只保留一个 AXI 状态机、一个
// line buffer 和一个 beat counter。任一时刻只处理一笔事务；write 优先级只用于
// 非法的同拍竞争场景，正常 control/maintenance 调度保证两个请求互斥。
`include "common/assertions.svh"

module cache_line_axi_engine
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
  localparam int unsigned BeatIndexW = (LineBeats > 1) ? $clog2(LineBeats) : 1
) (
  input logic clk_i,
  input logic rst_ni,

  axi_line_read_if.handler line_read,
  axi_line_write_if.handler line_write,
  axi4_if.master axi
);

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
  logic operation_write_q;
  logic [BlockAddrW-1:0] block_addr_q;
  logic [LineBits-1:0] line_buffer_q;
  logic [BeatIndexW-1:0] beat_index_q;
  logic error_q;

  logic read_req_fire;
  logic write_req_fire;
  logic response_fire;
  logic aw_fire;
  logic w_fire;
  logic b_fire;
  logic ar_fire;
  logic r_fire;
  logic expected_last;
  logic read_beat_error;
  logic write_response_error;

  function automatic word_t block_byte_address(input logic [BlockAddrW-1:0] block_addr);
    word_t address;

    address = word_t'(block_addr);
    return address << BlockOffsetW;
  endfunction

  assign read_req_fire = line_read.req_valid && line_read.req_ready;
  assign write_req_fire = line_write.req_valid && line_write.req_ready;
  assign response_fire = (line_read.rsp_valid && line_read.rsp_ready) ||
      (line_write.rsp_valid && line_write.rsp_ready);
  assign aw_fire = axi.awvalid && axi.awready;
  assign w_fire = axi.wvalid && axi.wready;
  assign b_fire = axi.bvalid && axi.bready;
  assign ar_fire = axi.arvalid && axi.arready;
  assign r_fire = axi.rvalid && axi.rready;
  assign expected_last = beat_index_q == BeatIndexW'(LineBeats - 1);
  assign write_response_error = (axi.b_payload.id != IdWidth'(AxiId)) ||
      (axi.b_payload.resp != AXI4_RESP_OKAY);
  assign read_beat_error = (axi.r_payload.id != IdWidth'(AxiId)) ||
      (axi.r_payload.resp != AXI4_RESP_OKAY) || (axi.r_payload.last != expected_last);

  always_comb begin
    axi.awvalid = 1'b0;
    axi.aw_payload = '0;
    axi.wvalid = 1'b0;
    axi.w_payload = '0;
    axi.bready = 1'b0;
    axi.arvalid = 1'b0;
    axi.ar_payload = '0;
    axi.rready = 1'b0;

    // 单状态机不接受并发事务。若两个请求意外同拍出现，write 获得确定优先级。
    line_write.req_ready = (state_q == StateIdle) && !ReadOnly;
    line_read.req_ready = (state_q == StateIdle) && (ReadOnly || !line_write.req_valid);
    line_write.rsp_valid = (state_q == StateResponse) && operation_write_q;
    line_write.rsp_payload.error = error_q;
    line_read.rsp_valid = (state_q == StateResponse) && !operation_write_q;
    line_read.rsp_payload.line = line_buffer_q;
    line_read.rsp_payload.error = error_q;

    unique case (state_q)
      StateWriteAddress: begin
        axi.awvalid = 1'b1;
        axi.aw_payload.addr = block_byte_address(block_addr_q);
        axi.aw_payload.id = IdWidth'(AxiId);
        axi.aw_payload.len = 8'(LineBeats - 1);
        axi.aw_payload.size = 3'd2;
        axi.aw_payload.burst = AXI4_BURST_INCR;
      end

      StateWriteData: begin
        axi.wvalid = 1'b1;
        axi.w_payload.data = line_buffer_q[int'(beat_index_q)*XLen+:XLen];
        axi.w_payload.strb = '1;
        axi.w_payload.last = expected_last;
      end

      StateWriteResponse: axi.bready = 1'b1;

      StateReadAddress: begin
        axi.arvalid = 1'b1;
        axi.ar_payload.addr = block_byte_address(block_addr_q);
        axi.ar_payload.id = IdWidth'(AxiId);
        axi.ar_payload.len = 8'(LineBeats - 1);
        axi.ar_payload.size = 3'd2;
        axi.ar_payload.burst = AXI4_BURST_INCR;
      end

      StateReadData: axi.rready = 1'b1;

      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StateIdle;
      operation_write_q <= 1'b0;
      beat_index_q <= '0;
      error_q <= 1'b0;
    end else begin
      unique case (state_q)
        StateIdle: begin
          if (write_req_fire) begin
            operation_write_q <= 1'b1;
            block_addr_q <= line_write.req_payload.block_addr;
            line_buffer_q <= line_write.req_payload.line;
            beat_index_q <= '0;
            error_q <= 1'b0;
            state_q <= StateWriteAddress;
          end else if (read_req_fire) begin
            operation_write_q <= 1'b0;
            block_addr_q <= line_read.req_payload.block_addr;
            beat_index_q <= '0;
            error_q <= 1'b0;
            state_q <= StateReadAddress;
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
            error_q <= write_response_error;
            state_q <= StateResponse;
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
            line_buffer_q[int'(beat_index_q)*XLen+:XLen] <= axi.r_payload.data;
            error_q <= error_q || read_beat_error;
            if (axi.r_payload.last || expected_last) begin
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

  // verilog_format: off
  `ASSERT_INIT(CacheLineAxiBeatCountValid,
               (LineBeats > 0) && (LineBeats <= 256),
               "AXI4 bursts contain between one and 256 beats.")
  `ASSERT(CacheLineAxiRequestsExclusive,
          !(line_read.req_valid && line_write.req_valid),
          clk_i, !rst_ni,
          "Line read and write requests must not compete for the blocking AXI engine.")
  `ASSERT(CacheLineReadRequestStable,
          line_read.req_valid && !line_read.req_ready |=>
              $stable({line_read.req_valid, line_read.req_payload}),
          clk_i, !rst_ni,
          "Line-read request must remain stable while backpressured.")
  `ASSERT(CacheLineWriteRequestStable,
          line_write.req_valid && !line_write.req_ready |=>
              $stable({line_write.req_valid, line_write.req_payload}),
          clk_i, !rst_ni,
          "Line-write request must remain stable while backpressured.")
  `ASSERT(CacheLineReadResponseStable,
          line_read.rsp_valid && !line_read.rsp_ready |=>
              $stable({line_read.rsp_valid, line_read.rsp_payload}),
          clk_i, !rst_ni,
          "Line-read response must remain stable while backpressured.")
  `ASSERT(CacheLineWriteResponseStable,
          line_write.rsp_valid && !line_write.rsp_ready |=>
              $stable({line_write.rsp_valid, line_write.rsp_payload}),
          clk_i, !rst_ni,
          "Line-write response must remain stable while backpressured.")
  `ASSERT(CacheLineAxiAwStable,
          axi.awvalid && !axi.awready |=>
              $stable({axi.awvalid, axi.aw_payload}),
          clk_i, !rst_ni,
          "AXI write address payload must remain stable while backpressured.")
  `ASSERT(CacheLineAxiWStable,
          axi.wvalid && !axi.wready |=>
              $stable({axi.wvalid, axi.w_payload}),
          clk_i, !rst_ni,
          "AXI write data payload must remain stable while backpressured.")
  `ASSERT(CacheLineAxiArStable,
          axi.arvalid && !axi.arready |=>
              $stable({axi.arvalid, axi.ar_payload}),
          clk_i, !rst_ni,
          "AXI read address payload must remain stable while backpressured.")
  // verilog_format: on

  if (ReadOnly) begin : gen_read_only_assertions
    `ASSERT(CacheLineAxiReadOnlyWriteRequest, !line_write.req_valid, clk_i, !rst_ni,
            "A read-only cache must never request a line writeback.")
    `ASSERT(CacheLineAxiReadOnlyAxiWrite, !axi.awvalid && !axi.wvalid && !axi.bready, clk_i,
            !rst_ni, "A read-only line engine must never drive AXI writes.")
  end

  `ASSERT_INIT(CacheLineAxiAddressWidthSupported, AddrWidth == XLen)
  `ASSERT_INIT(CacheLineAxiDataWidthSupported, DataWidth == XLen)
  `ASSERT_INIT(CacheLineAxiAddressAndIdWidthsValid, AddrWidth > 0 && IdWidth > 0)
  `ASSERT_INIT(CacheLineAxiDataWidthValid,
               DataWidth >= 8 && (DataWidth % 8) == 0 && (DataWidth & (DataWidth - 1)) == 0)
  `ASSERT_INIT(CacheLineAxiAwAddrWidth, $bits(axi.aw_payload.addr) == AddrWidth)
  `ASSERT_INIT(CacheLineAxiDataWidth, $bits(axi.w_payload.data) == DataWidth)
  `ASSERT_INIT(CacheLineAxiIdWidth, $bits(axi.aw_payload.id) == IdWidth)
  `ASSERT_INIT(CacheLineAxiIdFits, (AxiId >> IdWidth) == 0)
  `ASSERT_INIT(CacheLineAxiInterfaceWidths, $bits(line_read.req_payload.block_addr)
               == BlockAddrW && $bits(line_read.rsp_payload.line) == LineBits && $bits
               (line_write.req_payload.block_addr) == BlockAddrW && $bits
               (line_write.req_payload.line) == LineBits)

endmodule
