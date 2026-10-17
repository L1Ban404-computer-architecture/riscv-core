// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

module stream_register_tb;
  bit clk = 0;
  bit rst_n = 0;
  bit flush = 0;
  bit input_valid = 0;
  logic input_ready;
  logic [31:0] input_data = 0;
  logic output_valid;
  bit output_ready = 0;
  logic [31:0] output_data;

  stream_register #(.T(logic [31:0])) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .valid_i(input_valid), .ready_o(input_ready), .data_i(input_data),
    .valid_o(output_valid), .ready_i(output_ready), .data_o(output_data)
  );

  task automatic tick;
    #1; clk = 1;
    #1; clk = 0;
    #1;
  endtask

  task automatic expect_output(input bit valid, input logic [31:0] data);
    #1;
    assert (output_valid == valid) else $fatal(1, "output valid");
    if (valid) assert (output_data == data) else $fatal(1, "output data");
  endtask

  initial begin
    tick();
    rst_n = 1;
    expect_output(0, 0);

    // 空载也不组合穿透；已经接收的数据在反压期间保持。
    input_valid = 1;
    input_data = 11;
    expect_output(0, 0);
    assert (input_ready) else $fatal(1, "empty register must accept");
    tick();
    input_data = 22;
    expect_output(1, 11);
    assert (!input_ready) else $fatal(1, "full register must backpressure");
    tick();
    expect_output(1, 11);

    // 满载同拍弹出和替换。
    output_ready = 1;
    #1;
    assert (input_ready) else $fatal(1, "same-cycle replacement");
    tick();
    input_valid = 0;
    output_ready = 0;
    expect_output(1, 22);

    // 下游不 ready 时也必须立即取消旧输出，并释放入口容量。
    flush = 1;
    expect_output(0, 0);
    assert (input_ready) else $fatal(1, "flush must release capacity");
    tick();
    flush = 0;
    expect_output(0, 0);

    // 从空载开始，flush 同拍接收的新事务在下一拍可见。
    flush = 1;
    input_valid = 1;
    input_data = 33;
    tick();
    expect_output(0, 0);
    flush = 0;
    input_valid = 0;
    expect_output(1, 33);

    // 满载且下游反压：取消 33，保留新输入 44，不能误当作已弹出。
    flush = 1;
    input_valid = 1;
    input_data = 44;
    expect_output(0, 0);
    assert (input_ready) else $fatal(1, "flush must accept into full register");
    tick();
    flush = 0;
    input_valid = 0;
    expect_output(1, 44);
    tick();
    expect_output(1, 44);

    // 每个 flush 都取消其之前的事务；连续 flush 只留下最后一次接收值。
    flush = 1;
    input_valid = 1;
    input_data = 55;
    tick();
    input_data = 66;
    tick();
    flush = 0;
    input_valid = 0;
    expect_output(1, 66);
    output_ready = 1;
    tick();
    expect_output(0, 0);

    // 复位优先于 flush 同拍的新输入。
    rst_n = 0;
    flush = 1;
    input_valid = 1;
    tick();
    flush = 0;
    input_valid = 0;
    rst_n = 1;
    expect_output(0, 0);

    $display("PASS: stream register backpressure, replacement and flush input acceptance");
    $finish;
  end
endmodule
