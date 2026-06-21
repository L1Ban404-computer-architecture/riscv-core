// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module regfile (
  input logic clk_i,

  input reg_addr_t rs1_addr_i,
  input reg_addr_t rs2_addr_i,
  output word_t rs1_value_o,
  output word_t rs2_value_o,

  input wb_req_bus_t wb_req_i
);

  // 普通 GPR 的复位值在 RISC-V 架构中未定义。阵列不接复位可以避免为
  // 31 个数据寄存器铺设复位网络；x0 由读写逻辑强制为零。
  word_t regs_q[31:1];
  logic wb_write;

  assign wb_write = wb_req_i.valid && wb_req_i.data_valid && (wb_req_i.rd_addr != ZeroReg);

  always_ff @(posedge clk_i) begin
    if (wb_write) begin
      regs_q[wb_req_i.rd_addr] <= wb_req_i.wdata;
    end
  end

  always_comb begin
    rs1_value_o = '0;
    if (rs1_addr_i != ZeroReg) begin
      // WB 和 ID 同周期访问同一寄存器时显式旁路，避免依赖 SRAM/寄存器阵列
      // 的 read-during-write 工艺语义。
      if (wb_write && (wb_req_i.rd_addr == rs1_addr_i)) begin
        rs1_value_o = wb_req_i.wdata;
      end else begin
        rs1_value_o = regs_q[rs1_addr_i];
      end
    end

    rs2_value_o = '0;
    if (rs2_addr_i != ZeroReg) begin
      if (wb_write && (wb_req_i.rd_addr == rs2_addr_i)) begin
        rs2_value_o = wb_req_i.wdata;
      end else begin
        rs2_value_o = regs_q[rs2_addr_i];
      end
    end
  end

endmodule
