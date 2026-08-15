// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Cache 单字数据 Bank。
//
// 实现按组索引访问的单读单写数据存储体，并寄存同步读结果。
// 同一周期不得同时读写本 bank；数据阵列和读数据寄存器不复位，无效内容由
// 上层元数据屏蔽。
`include "common/assertions.svh"

module cache_data_bank
  import riscv_common_pkg::*;
  import cache_pkg::*;
#(
  parameter int unsigned SetCount = CacheDefaultSetCount,
  localparam int unsigned SetIndexW =
      (SetCount > 1) ? $clog2(SetCount) : 1
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 读端口
  input logic read_valid_i,
  input logic [SetIndexW-1:0] read_set_i,
  output word_t read_data_o,

  // 写端口
  input logic write_valid_i,
  input logic [SetIndexW-1:0] write_set_i,
  input word_t write_data_i
);

  ////////////////////////
  // 数据存储与同步访问 //
  ////////////////////////

  word_t data_mem[SetCount];
  word_t read_data_q;

  assign read_data_o = read_data_q;

  always_ff @(posedge clk_i) begin
    if (read_valid_i) read_data_q <= data_mem[read_set_i];
    if (write_valid_i) data_mem[write_set_i] <= write_data_i;
  end

  //////////////////
  // 端口互斥断言 //
  //////////////////

  `ASSERT(CacheDataBankReadWriteExclusive,
          !(read_valid_i && write_valid_i),
          clk_i, !rst_ni,
          "Cache array scheduling must not read and write one data bank concurrently.")

endmodule
