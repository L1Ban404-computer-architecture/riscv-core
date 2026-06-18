// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

/* verilator lint_off UNUSEDSIGNAL */
module mem_stage (
  input logic clk_i,
  input logic rst_ni,

  // EX -> MEM 事务通道。MEM stage 未来会在内部维护 LSU 请求/响应队列，
  // 因此不依赖顶层额外 pipeline_regs 插入寄存器。
  input logic ex_mem_valid_i,
  output logic ex_mem_ready_o,
  input ex_mem_bus_t ex_mem_bus_i,

  // 数据存储器接口。这个接口是核心边界上的轻量级内存事务接口，后续可由
  // 外部 adapter 转接到具体 SoC 总线。
  output logic dmem_req_o,
  output logic dmem_we_o,
  output byte_en_t dmem_byte_en_o,
  output word_t dmem_addr_o,
  output word_t dmem_wdata_o,
  input logic dmem_gnt_i,
  input logic dmem_rvalid_i,
  input word_t dmem_rdata_i,

  // MEM 产生的写回候选，用于 load 数据返回后的前递判断。
  output wb_req_bus_t mem_wb_req_o,

  // MEM -> WB 事务通道。MEM debug 会记录访存请求和响应行为。
  output logic mem_wb_valid_o,
  input logic mem_wb_ready_i,
  output mem_wb_bus_t mem_wb_bus_o
);

  // 占位实现：暂不发起真实数据访问，后续在此加入 LSU 状态机/FIFO。
  assign ex_mem_ready_o = mem_wb_ready_i;
  assign dmem_req_o = 1'b0;
  assign dmem_we_o = 1'b0;
  assign dmem_byte_en_o = '0;
  assign dmem_addr_o = '0;
  assign dmem_wdata_o = '0;
  assign mem_wb_req_o = '0;
  assign mem_wb_valid_o = 1'b0;
  assign mem_wb_bus_o = '0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
