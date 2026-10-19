// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// RV32 整数寄存器堆，提供两路组合读和一路同步写。
// x0 固定为零；同周期写回值由 ID 前递单元提供。
module regfile
  import riscv_core_pkg::*;
(
  // 时钟
  input logic clk_i,

  // 读写接口
  gpr_read_if.responder gpr_read,
  gpr_write_if.consumer wb
);

  // 普通 GPR 的复位值在 RISC-V 架构中未定义。阵列不接复位可以避免为
  // 普通数据寄存器铺设复位网络；x0 由读写逻辑强制为零。
  word_t regs_q[GprCount-1:1];
  logic wb_write;

  assign wb_write = wb.valid && (wb.payload.rd_addr != ZeroReg) && (int'(wb.payload.rd_addr) < GprCount);

  // 组合读取

  always_comb begin
    gpr_read.rs1_value = '0;
    if ((gpr_read.rs1_addr != ZeroReg) && (int'(gpr_read.rs1_addr) < GprCount)) begin
      gpr_read.rs1_value = regs_q[gpr_read.rs1_addr];
    end

    gpr_read.rs2_value = '0;
    if ((gpr_read.rs2_addr != ZeroReg) && (int'(gpr_read.rs2_addr) < GprCount)) begin
      gpr_read.rs2_value = regs_q[gpr_read.rs2_addr];
    end
  end

  always_ff @(posedge clk_i) begin
    if (wb_write) begin
      regs_q[wb.payload.rd_addr] <= wb.payload.wdata;
    end
  end

endmodule
