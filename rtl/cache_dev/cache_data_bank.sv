// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// One 32-bit cache word bank.  Keeping every way/word bank in an independent
// 1R1W memory lets a lookup read one word from every way while victim reads and
// line installs operate on all word banks of one way in parallel.
`include "common/assertions.svh"

module cache_data_bank
  import riscv_common_pkg::*;
  import cache_pkg::*;
#(
  parameter int unsigned SetCount = CacheDefaultSetCount,
  localparam int unsigned SetIndexW =
      (SetCount > 1) ? $clog2(SetCount) : 1
) (
  input logic clk_i,
  input logic rst_ni,

  input logic read_valid_i,
  input logic [SetIndexW-1:0] read_set_i,
  output word_t read_data_o,

  input logic write_valid_i,
  input logic [SetIndexW-1:0] write_set_i,
  input word_t write_data_i
);

  word_t data_mem[SetCount];
  word_t read_data_q;

  assign read_data_o = read_data_q;

  always_ff @(posedge clk_i) begin
    if (read_valid_i) read_data_q <= data_mem[read_set_i];
    if (write_valid_i) data_mem[write_set_i] <= write_data_i;
  end

  `ASSERT(CacheDataBankReadWriteExclusive,
          !(read_valid_i && write_valid_i),
          clk_i, !rst_ni,
          "Cache array scheduling must not read and write one data bank concurrently.")

endmodule
