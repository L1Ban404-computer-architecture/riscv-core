// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 队列记分板检查顺序和取消，覆盖不同深度、旁路和同拍读写组合。
module stream_fifo_case #(
  parameter int unsigned Depth = 3,
  parameter bit FallThrough = 0,
  parameter bit SameCycleRW = 0,
  parameter bit Wrapper = 0
) (output bit done = 0);
  bit clk = 0, rst_n = 0, flush = 0, input_valid = 0, output_ready = 0;
  logic input_ready, output_valid;
  logic [31:0] input_data = 0, output_data;
  logic [$clog2(Depth+1)-1:0] usage;
  logic [31:0] expected[$];
  logic [31:0] random_q = 32'h12345678 + Depth;

  if (Wrapper) begin : gen_wrapper
    fall_through_register #(.T(logic [31:0])) dut (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .valid_i(input_valid), .ready_o(input_ready), .data_i(input_data),
      .valid_o(output_valid), .ready_i(output_ready), .data_o(output_data)
    );
    assign usage = '0;
  end else begin : gen_fifo
    stream_fifo #(.Depth(Depth), .FallThrough(FallThrough), .SameCycleRW(SameCycleRW),
                  .T(logic [31:0])) dut (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .usage_o(usage),
      .valid_i(input_valid), .ready_o(input_ready), .data_i(input_data),
      .valid_o(output_valid), .ready_i(output_ready), .data_o(output_data)
    );
  end

  task automatic cycle(input bit cancel, input bit send, input bit receive,
                       input logic [31:0] data);
    int old_size;
    flush = cancel;
    input_valid = send;
    output_ready = receive;
    input_data = data;
    #1;
    old_size = expected.size();
    if (cancel) begin
      assert (!output_valid && input_ready) else $fatal(1, "flush handshake");
      expected.delete();
      if (send) expected.push_back(data);
    end else begin
      if (old_size != 0) begin
        assert (output_valid && output_data == expected[0])
          else $fatal(1, "FIFO ordering: depth=%0d FT=%0d RW=%0d", Depth, FallThrough, SameCycleRW);
      end else begin
        assert (output_valid == (FallThrough && send)) else $fatal(1, "empty bypass valid");
        if (output_valid) assert (output_data == data) else $fatal(1, "empty bypass data");
      end
      if (old_size < Depth) assert (input_ready) else $fatal(1, "free capacity");
      else assert (input_ready == (SameCycleRW && receive)) else $fatal(1, "full capacity");
      if (output_valid && receive && old_size != 0) void'(expected.pop_front());
      if (send && input_ready && !(FallThrough && old_size == 0 && receive))
        expected.push_back(data);
    end
    clk = 1;
    #1; clk = 0;
    #1;
    if (!Wrapper) assert (int'(usage) == expected.size()) else $fatal(1, "FIFO usage");
  endtask

  initial begin
    // 复位必须优先于 flush 和新输入。
    flush = 1;
    input_valid = 1;
    #1; clk = 1;
    #1; clk = 0;
    #1;
    rst_n = 1;
    cycle(0, 0, 0, 0);
    for (int i = 0; i < Depth; i++) cycle(0, 1, 0, 32'(i));
    // 满载、下游反压时取消旧队列并保留新值；紧接着继续入队，检查尾指针。
    cycle(1, 1, 0, 99);
    cycle(0, 1, 0, 100);
    repeat (Depth + 1) cycle(0, 0, 1, 0);
    // 非零读写位置、连续冲刷，以及下游 ready 时禁止 flush 当拍直通。
    repeat (Depth + 2) cycle(0, 1, 1, 200);
    cycle(1, 1, 1, 300);
    cycle(1, 1, 1, 301);
    cycle(0, 0, 1, 0);
    cycle(1, 0, 0, 0);
    for (int i = 0; i < 250; i++) begin
      random_q = {random_q[30:0], random_q[31] ^ random_q[21] ^ random_q[1] ^ random_q[0]};
      cycle(random_q[5:3] == 0, random_q[0], random_q[1], 32'(1000 + i));
    end
    repeat (Depth + 1) cycle(0, 0, 1, 0);
    assert (expected.size() == 0) else $fatal(1, "FIFO must drain");
    done = 1;
  end
endmodule

module stream_fifo_tb;
  wire [12:0] done;
  for (genvar d = 0; d < 3; d++) begin : gen_depth
    for (genvar ft = 0; ft < 2; ft++) begin : gen_fallthrough
      for (genvar rw = 0; rw < 2; rw++) begin : gen_samecycle
        stream_fifo_case #(.Depth(d == 0 ? 1 : d == 1 ? 3 : 4),
                           .FallThrough(1'(ft)), .SameCycleRW(1'(rw))) test_case (
          .done(done[d*4 + ft*2 + rw])
        );
      end
    end
  end
  stream_fifo_case #(.Depth(1), .FallThrough(1), .SameCycleRW(1), .Wrapper(1)) wrapper_case (
    .done(done[12])
  );
  initial begin
    wait (&done);
    $display("PASS: FIFO ordering, pointer wrap and unified flush across 13 configurations");
    $finish;
  end
endmodule
