// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Ordered CoreBus scoreboard.  The driver supplies the expected completion
// alongside each request; it is recorded atomically on the request handshake.
module cache_corebus_scoreboard
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
#(
  parameter int unsigned Depth = 2048,
  parameter int unsigned CountW = (Depth > 1) ? $clog2(Depth + 1) : 1
) (
  input logic clk_i,
  input logic rst_ni,

  input logic request_valid_i,
  input logic request_ready_i,
  input logic response_valid_i,
  input logic response_ready_i,
  input word_t response_rdata_i,
  input logic response_error_i,
  input word_t expected_rdata_i,
  input logic expected_error_i,

  output logic empty_o,
  output logic [CountW-1:0] pending_o
);

  word_t expected_rdata_q[Depth];
  logic expected_error_q[Depth];
  int unsigned head_q;
  int unsigned tail_q;
  logic request_fire;
  logic response_fire;

  assign request_fire = request_valid_i && request_ready_i;
  assign response_fire = response_valid_i && response_ready_i;
  assign empty_o = pending_o == '0;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q <= 0;
      tail_q <= 0;
      pending_o <= '0;
    end else begin
      if (request_fire) begin
        if (tail_q >= Depth) $fatal(1, "Test scoreboard overflow.");
        expected_rdata_q[tail_q] <= expected_rdata_i;
        expected_error_q[tail_q] <= expected_error_i;
        tail_q <= tail_q + 1;
      end

      if (response_fire) begin
        if (pending_o == '0) $fatal(1, "Unexpected CoreBus response.");
        if (response_error_i !== expected_error_q[head_q]) begin
          $fatal(1, "CoreBus error mismatch at response %0d.", head_q);
        end
        if (!response_error_i &&
            (response_rdata_i !== expected_rdata_q[head_q])) begin
          $fatal(1,
                 "CoreBus data mismatch at response %0d: expected %08x, got %08x.",
                 head_q, expected_rdata_q[head_q], response_rdata_i);
        end
        head_q <= head_q + 1;
      end

      unique case ({request_fire, response_fire})
        2'b10: pending_o <= pending_o + CountW'(1);
        2'b01: pending_o <= pending_o - CountW'(1);
        default: ;
      endcase
    end
  end

endmodule
