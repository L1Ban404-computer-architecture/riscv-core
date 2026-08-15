// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// RV32 整数寄存器堆，提供两路组合读和一路同步写。
// x0 固定为零；同周期读写同一地址时，读端旁路本次写入值。
module regfile
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  // 时钟
  input logic clk_i,

  // 读取端口
  input reg_addr_t rs1_addr_i,
  input reg_addr_t rs2_addr_i,
  output word_t rs1_value_o,
  output word_t rs2_value_o,

  // 写回端口
  writeback_if.consumer wb
);

  //////////////////////
  // 寄存器阵列与写入 //
  //////////////////////

  // 普通 GPR 的复位值在 RISC-V 架构中未定义。阵列不接复位可以避免为
  // 31 个数据寄存器铺设复位网络；x0 由读写逻辑强制为零。
  word_t regs_q[31:1];
  logic wb_write;

  assign wb_write = wb.payload.valid && wb.payload.data_valid &&
      (wb.payload.rd_addr != ZeroReg);

  always_ff @(posedge clk_i) begin
    if (wb_write) begin
      regs_q[wb.payload.rd_addr] <= wb.payload.wdata;
    end
  end

  ////////////////////////
  // 组合读取与同拍旁路 //
  ////////////////////////

  always_comb begin
    rs1_value_o = '0;
    if (rs1_addr_i != ZeroReg) begin
      // WB 和 ID 同周期访问同一寄存器时显式旁路，避免依赖 SRAM/寄存器阵列
      // 的 read-during-write 工艺语义。
      if (wb_write && (wb.payload.rd_addr == rs1_addr_i)) begin
        rs1_value_o = wb.payload.wdata;
      end else begin
        rs1_value_o = regs_q[rs1_addr_i];
      end
    end

    rs2_value_o = '0;
    if (rs2_addr_i != ZeroReg) begin
      if (wb_write && (wb.payload.rd_addr == rs2_addr_i)) begin
        rs2_value_o = wb.payload.wdata;
      end else begin
        rs2_value_o = regs_q[rs2_addr_i];
      end
    end
  end

endmodule
