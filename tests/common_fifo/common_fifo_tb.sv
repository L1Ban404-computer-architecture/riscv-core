// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

module common_fifo_tb #(
  parameter int unsigned Depth = 1,
  parameter bit FallThrough = 1'b0,
  parameter bit SameCycleRW = 1'b1,
  parameter int unsigned CountW = (Depth > 1) ? $clog2(Depth + 1) : 1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic valid_i,
  output logic ready_o,
  input logic [31:0] data_i,
  output logic valid_o,
  input logic ready_i,
  output logic [31:0] data_o,
  output logic [CountW-1:0] usage_o,
  output logic [CountW-1:0] peek_usage_o,
  output logic [CountW-1:0] peek_valid_count_o,
  output logic config_fall_through_o,
  output logic config_same_cycle_rw_o,
  output logic [31:0] config_depth_o
);

  typedef logic [CountW-1:0] count_t;

  logic peek_ready;
  logic peek_valid;
  logic [31:0] peek_data;
  logic [31:0] peek_data_all [Depth];
  logic [Depth-1:0] peek_valid_all;

  assign config_fall_through_o = FallThrough;
  assign config_same_cycle_rw_o = SameCycleRW;
  assign config_depth_o = Depth;
  assign peek_valid_count_o = count_t'($countones(peek_valid_all));

  stream_fifo #(
    .Depth(Depth),
    .FallThrough(FallThrough),
    .SameCycleRW(SameCycleRW),
    .T(logic [31:0])
  ) u_stream_fifo (
    .clk_i,
    .rst_ni,
    .flush_i,
    .usage_o,
    .data_i,
    .valid_i,
    .ready_o,
    .data_o,
    .valid_o,
    .ready_i
  );

  peek_fifo #(
    .Depth(Depth),
    .FallThrough(FallThrough),
    .SameCycleRW(SameCycleRW),
    .T(logic [31:0])
  ) u_peek_fifo (
    .clk_i,
    .rst_ni,
    .flush_i,
    .usage_o(peek_usage_o),
    .data_i,
    .valid_i,
    .ready_o(peek_ready),
    .data_o(peek_data),
    .valid_o(peek_valid),
    .ready_i,
    .data_all_o(peek_data_all),
    .valid_all_o(peek_valid_all)
  );

  always_comb begin
    assert (ready_o == peek_ready);
    assert (valid_o == peek_valid);
    assert (data_o == peek_data);
    assert (usage_o == peek_usage_o);
  end

endmodule
