// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Blocking AXI4 writeback/refill engine.  One line buffer is reused for the
// outgoing dirty victim and the subsequent incoming refill.
`include "common/assertions.svh"

module cache_refill_engine
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
  import cache_pkg::*;
#(
  parameter bit ReadOnly = CacheDefaultReadOnly,
  parameter int unsigned BlockBytes = CacheDefaultBlockBytes,
  parameter axi4_id_t AxiId = DCACHE_AXI_ID,
  localparam int unsigned BlockOffsetW = $clog2(BlockBytes),
  localparam int unsigned BlockAddrW = XLen - BlockOffsetW,
  localparam int unsigned LineBits = BlockBytes * ByteW,
  localparam int unsigned LineBeats = BlockBytes / StrbW,
  localparam int unsigned BeatIndexW =
      (LineBeats > 1) ? $clog2(LineBeats) : 1
) (
  input logic clk_i,
  input logic rst_ni,

  input logic refill_req_valid_i,
  output logic refill_req_ready_o,
  input logic [BlockAddrW-1:0] refill_req_block_addr_i,
  input logic refill_req_writeback_valid_i,
  input logic [BlockAddrW-1:0] refill_req_writeback_block_addr_i,
  input logic [LineBits-1:0] refill_req_writeback_data_i,

  output logic refill_rsp_valid_o,
  input logic refill_rsp_ready_i,
  output logic [LineBits-1:0] refill_rsp_data_o,
  output logic refill_rsp_error_o,

  output axi4_req_t axi_req_o,
  input axi4_resp_t axi_resp_i
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
    assign request_writeback = refill_req_writeback_valid_i;
  end

  assign request_fire = refill_req_valid_i && refill_req_ready_o;
  assign response_fire = refill_rsp_valid_o && refill_rsp_ready_i;
  assign aw_fire = axi_req_o.awvalid && axi_resp_i.awready;
  assign w_fire = axi_req_o.wvalid && axi_resp_i.wready;
  assign b_fire = axi_resp_i.bvalid && axi_req_o.bready;
  assign ar_fire = axi_req_o.arvalid && axi_resp_i.arready;
  assign r_fire = axi_resp_i.rvalid && axi_req_o.rready;
  assign expected_last = beat_index_q == BeatIndexW'(LineBeats - 1);
  assign write_response_error =
      (axi_resp_i.bid != AxiId) || (axi_resp_i.bresp != AXI4_RESP_OKAY);
  assign read_beat_error = (axi_resp_i.rid != AxiId) ||
      (axi_resp_i.rresp != AXI4_RESP_OKAY) ||
      (axi_resp_i.rlast != expected_last);

  always_comb begin
    axi_req_o = '0;
    refill_req_ready_o = state_q == StateIdle;
    refill_rsp_valid_o = state_q == StateResponse;
    refill_rsp_data_o = line_buffer_q;
    refill_rsp_error_o = error_q;

    unique case (state_q)
      StateWriteAddress: begin
        axi_req_o.awvalid = 1'b1;
        axi_req_o.awaddr = block_byte_address(writeback_block_addr_q);
        axi_req_o.awid = AxiId;
        axi_req_o.awlen = 8'(LineBeats - 1);
        axi_req_o.awsize = 3'd2;
        axi_req_o.awburst = AXI4_BURST_INCR;
      end

      StateWriteData: begin
        axi_req_o.wvalid = 1'b1;
        axi_req_o.wdata =
            line_buffer_q[int'(beat_index_q) * XLen +: XLen];
        axi_req_o.wstrb = '1;
        axi_req_o.wlast = expected_last;
      end

      StateWriteResponse: begin
        axi_req_o.bready = 1'b1;
      end

      StateReadAddress: begin
        axi_req_o.arvalid = 1'b1;
        axi_req_o.araddr = block_byte_address(refill_block_addr_q);
        axi_req_o.arid = AxiId;
        axi_req_o.arlen = 8'(LineBeats - 1);
        axi_req_o.arsize = 3'd2;
        axi_req_o.arburst = AXI4_BURST_INCR;
      end

      StateReadData: begin
        axi_req_o.rready = 1'b1;
      end

      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StateIdle;
      beat_index_q <= '0;
      error_q <= 1'b0;
    end else begin
      unique case (state_q)
        StateIdle: begin
          if (request_fire) begin
            refill_block_addr_q <= refill_req_block_addr_i;
            writeback_block_addr_q <= refill_req_writeback_block_addr_i;
            beat_index_q <= '0;
            error_q <= 1'b0;
            if (request_writeback) begin
              line_buffer_q <= refill_req_writeback_data_i;
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
                axi_resp_i.rdata;
            error_q <= error_q || read_beat_error;
            if (axi_resp_i.rlast || expected_last) begin
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
  `ASSERT_INIT(CacheRefillLineBeatCountValid,
               (LineBeats > 0) && (LineBeats <= 256),
               "AXI4 bursts contain between one and 256 beats.")
  `ASSERT(CacheRefillRequestStable,
          refill_req_valid_i && !refill_req_ready_o |=>
              $stable({refill_req_valid_i, refill_req_block_addr_i,
                       refill_req_writeback_valid_i,
                       refill_req_writeback_block_addr_i,
                       refill_req_writeback_data_i}),
          clk_i, !rst_ni,
          "Refill request payload must remain stable while backpressured.")
  `ASSERT(CacheRefillResponseStable,
          refill_rsp_valid_o && !refill_rsp_ready_i |=>
              $stable({refill_rsp_valid_o, refill_rsp_data_o,
                       refill_rsp_error_o}),
          clk_i, !rst_ni,
          "Refill response must remain stable while backpressured.")
  `ASSERT(CacheRefillAwStable,
          axi_req_o.awvalid && !axi_resp_i.awready |=>
              $stable({axi_req_o.awvalid, axi_req_o.awaddr, axi_req_o.awid,
                       axi_req_o.awlen,
                       axi_req_o.awsize, axi_req_o.awburst}),
          clk_i, !rst_ni,
          "AXI write address payload must remain stable while backpressured.")
  `ASSERT(CacheRefillWStable,
          axi_req_o.wvalid && !axi_resp_i.wready |=>
              $stable({axi_req_o.wvalid, axi_req_o.wdata, axi_req_o.wstrb,
                       axi_req_o.wlast}),
          clk_i, !rst_ni,
          "AXI write data payload must remain stable while backpressured.")
  `ASSERT(CacheRefillArStable,
          axi_req_o.arvalid && !axi_resp_i.arready |=>
              $stable({axi_req_o.arvalid, axi_req_o.araddr, axi_req_o.arid,
                       axi_req_o.arlen,
                       axi_req_o.arsize, axi_req_o.arburst}),
          clk_i, !rst_ni,
          "AXI read address payload must remain stable while backpressured.")
  // verilog_format: on

  if (ReadOnly) begin : gen_read_only_assertions
    `ASSERT(CacheRefillEngineReadOnlyWriteback,
            refill_req_valid_i |-> !refill_req_writeback_valid_i,
            clk_i, !rst_ni,
            "A read-only cache must never request a dirty writeback.")
    `ASSERT(CacheRefillEngineReadOnlyAxiWrite,
            !axi_req_o.awvalid && !axi_req_o.wvalid && !axi_req_o.bready,
            clk_i, !rst_ni,
            "A read-only refill engine must never drive AXI writes.")
  end

endmodule
