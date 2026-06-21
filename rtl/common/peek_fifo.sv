// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "common/assertions.svh"

// 小深度、全条目可观察的顺序 FIFO。FallThrough 控制空队列组合旁路，
// SameCycleRW 控制满队列能否在 pop 的同周期接收新条目。
module peek_fifo #(
  parameter int unsigned Depth = 2,
  parameter bit FallThrough = 1'b0,
  parameter bit SameCycleRW = 1'b1,
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
  input logic ready_i,

  output T data_all_o[Depth],
  output logic [Depth-1:0] valid_all_o
);

  typedef logic [PtrW-1:0] ptr_t;
  typedef logic [CountW-1:0] count_t;

  // 数据阵列不复位；count_q/slot_valid_q 会屏蔽无效内容。这样可以避免为
  // 宽事务总线生成大量复位触发器和复位布线。
  T mem_q[Depth];
  logic [Depth-1:0] slot_valid_q;
  ptr_t read_ptr_q;
  ptr_t write_ptr_q;
  count_t count_q;

  logic stored_valid;
  logic push;
  logic pop;
  logic bypass_pop;

  function automatic ptr_t next_ptr(input ptr_t ptr);
    if (ptr == ptr_t'(Depth - 1)) return '0;
    return ptr + ptr_t'(1'b1);
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
  assign data_all_o = mem_q;
  assign valid_all_o = slot_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      slot_valid_q <= '0;
      read_ptr_q <= '0;
      write_ptr_q <= '0;
      count_q <= '0;
    end else if (flush_i) begin
      slot_valid_q <= '0;
      read_ptr_q <= '0;
      write_ptr_q <= '0;
      count_q <= '0;
    end else begin
      if (pop && stored_valid) begin
        slot_valid_q[read_ptr_q] <= 1'b0;
        read_ptr_q <= next_ptr(read_ptr_q);
      end

      if (push && !bypass_pop) begin
        mem_q[write_ptr_q] <= data_i;
        slot_valid_q[write_ptr_q] <= 1'b1;
        write_ptr_q <= next_ptr(write_ptr_q);
      end

      case ({
        push && !bypass_pop, pop && stored_valid
      })
        2'b10: count_q <= count_q + count_t'(1'b1);
        2'b01: count_q <= count_q - count_t'(1'b1);
        default: count_q <= count_q;
      endcase
    end
  end

  // verilog_format: off
  `ASSERT_INIT(PeekFifoDepthValid, Depth > 0, "Depth must be greater than zero.")
  `ASSERT(PeekFifoCountValid, count_q <= count_t'(Depth), clk_i, !rst_ni,
          "FIFO usage must not exceed Depth.")
  `ASSERT(PeekFifoSlotCountValid, count_t'($countones(slot_valid_q)) == count_q,
          clk_i, !rst_ni, "FIFO slot valid bits must match usage.")
  `ASSERT(PeekFifoOutputValidStable, valid_o && !ready_i |=> valid_o,
          clk_i, !rst_ni || flush_i,
          "FIFO output valid must remain asserted while waiting for ready.")
  `ASSERT_STABLE(PeekFifoOutputDataStable, valid_o, ready_i, data_o, T'('0),
                 clk_i, !rst_ni || flush_i,
                 "FIFO output data must remain stable while waiting for ready.")
  // verilog_format: on

endmodule
