// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "common/assertions.svh"

// 小深度顺序 FIFO。FallThrough 允许空队列组合旁路，SameCycleRW 允许满队列
// 在 pop 的同周期接收新条目。数据阵列不复位，由 count_q 屏蔽无效内容。
module stream_fifo #(
  parameter int unsigned Depth = 2,
  parameter bit FallThrough = 1'b0,
  parameter bit SameCycleRW = 1'b0,
  parameter type T = logic,
  parameter int unsigned PtrW = (Depth > 1) ? $clog2(Depth) : 1,
  parameter int unsigned CountW = (Depth > 1) ? $clog2(Depth + 1) : 1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  output logic [CountW-1:0] usage_o,

  input T data_i,
  input logic valid_i,
  output logic ready_o,

  output T data_o,
  output logic valid_o,
  input logic ready_i
);

  typedef logic [PtrW-1:0] ptr_t;
  typedef logic [CountW-1:0] count_t;

  T mem_q[Depth];
  ptr_t read_ptr_q;
  ptr_t write_ptr_q;
  count_t count_q;
  logic stored_valid;
  logic push;
  logic pop;
  logic bypass_pop;

  function automatic ptr_t next_ptr(input ptr_t ptr);
    if (ptr == ptr_t'(Depth - 1)) return '0;
    return ptr + ptr_t'(1);
  endfunction

  assign stored_valid = (count_q != '0);
  assign valid_o = stored_valid || (FallThrough && valid_i);
  assign data_o = (FallThrough && !stored_valid) ? data_i : mem_q[read_ptr_q];
  assign pop = valid_o && ready_i;
  assign ready_o = (count_q < count_t'(Depth)) ||
      (SameCycleRW && stored_valid && ready_i);
  assign push = valid_i && ready_o;
  assign bypass_pop = FallThrough && !stored_valid && push && pop;
  assign usage_o = count_q;

  always_ff @(posedge clk_i) begin
    if (rst_ni && !flush_i && push && !bypass_pop)
      mem_q[write_ptr_q] <= data_i;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_ptr_q <= '0;
      write_ptr_q <= '0;
      count_q <= '0;
    end else if (flush_i) begin
      read_ptr_q <= '0;
      write_ptr_q <= '0;
      count_q <= '0;
    end else begin
      if (pop && stored_valid) read_ptr_q <= next_ptr(read_ptr_q);
      if (push && !bypass_pop) write_ptr_q <= next_ptr(write_ptr_q);
      unique case ({push && !bypass_pop, pop && stored_valid})
        2'b10: count_q <= count_q + count_t'(1);
        2'b01: count_q <= count_q - count_t'(1);
        default: ;
      endcase
    end
  end

  // verilog_format: off
  `ASSERT_INIT(StreamFifoDepthValid, Depth > 0, "Depth must be greater than zero.")
  `ASSERT(StreamFifoCountValid, count_q <= count_t'(Depth), clk_i, !rst_ni,
          "FIFO usage must not exceed Depth.")
  `ASSERT(StreamFifoOutputValidStable, valid_o && !ready_i |=> valid_o,
          clk_i, !rst_ni || flush_i,
          "FIFO output valid must remain asserted while waiting for ready.")
  `ASSERT_STABLE(StreamFifoOutputDataStable, valid_o, ready_i, data_o, T'('0),
                 clk_i, !rst_ni || flush_i,
                 "FIFO output data must remain stable while waiting for ready.")
  // verilog_format: on

endmodule
