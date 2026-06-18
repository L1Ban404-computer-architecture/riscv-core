// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

/* verilator lint_off UNUSEDSIGNAL */
module if_stage (
  input logic clk_i,
  input logic rst_ni,

  // boot_pc_i 是 IF stage 内部 PC 队列的初始值。真实 PC 寄存器墙会放在
  // IF stage 内部，而不是由 riscv_core 顶层额外插入 pipeline_regs。
  input pc_t boot_pc_i,

  // redirect_i 只来自 EX stage。它表示“前端改道”，用于丢弃尚未进入 EX
  // 的年轻事务；它不负责冲刷 EX/MEM/WB 中已经有效的指令。
  input redirect_bus_t redirect_i,

  // 取指存储器请求接口。当前文件只定义接口骨架，后续会在 IF 内部实现
  // PC 选择、请求保持、响应收集以及 if_id 深度队列。
  output logic imem_req_o,
  output pc_t imem_addr_o,
  input logic imem_gnt_i,
  input logic imem_rvalid_i,
  input instr_t imem_rdata_i,

  // IF -> ID 事务通道。if_id 的寄存器墙/FIFO 属于 IF stage 内部。
  output logic if_id_valid_o,
  input logic if_id_ready_i,
  output if_id_bus_t if_id_bus_o
);

  // 占位实现：本阶段目前只声明互联边界，不产生真实取指事务。
  // 后续实现时应删除这些默认赋值，并在 IF 内部维护 PC 与 if_id 队列。
  assign imem_req_o = 1'b0;
  assign imem_addr_o = boot_pc_i;
  assign if_id_valid_o = 1'b0;
  assign if_id_bus_o = '0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
