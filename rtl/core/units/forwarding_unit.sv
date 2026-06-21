// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module forwarding_unit #(
  parameter int unsigned MemOutstandingDepth = 2
) (
  input reg_addr_bus_t reg_addr_i,
  input word_t rs1_value_i,
  input word_t rs2_value_i,
  input decode_ctrl_bus_t ctrl_i,
  input wb_req_bus_t ex_wb_req_i,
  input wb_req_bus_t mem_pending_wb_req_i[MemOutstandingDepth],
  input wb_req_bus_t mem_wb_req_i,
  output word_t rs1_value_o,
  output word_t rs2_value_o,
  output logic stall_o
);

  logic conditional_branch;
  logic rs1_used;
  logic rs2_used;
  logic rs1_pending;
  logic rs2_pending;

  always_comb begin
    rs1_pending = 1'b0;
    rs2_pending = 1'b0;

    // outstanding FIFO 中只暴露尚未获得数据的 load。这里只需要比较地址
    // 并产生 stall，不需要为每个条目生成数据选择器。
    for (int unsigned i = 0; i < MemOutstandingDepth; i++) begin
      if (mem_pending_wb_req_i[i].valid && (mem_pending_wb_req_i[i].rd_addr == reg_addr_i.rs1_addr))
        rs1_pending = 1'b1;
      if (mem_pending_wb_req_i[i].valid && (mem_pending_wb_req_i[i].rd_addr == reg_addr_i.rs2_addr))
        rs2_pending = 1'b1;
    end
  end

  always_comb begin
    conditional_branch = 1'b0;
    case (ctrl_i.branch_op)
      BR_NONE, BR_JAL, BR_JALR: conditional_branch = 1'b0;
      BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU: conditional_branch = 1'b1;
      default: ;
    endcase

    // 只检查指令真正读取的源寄存器，编码中无语义的 rs 字段不会产生
    // LUI、JAL、FENCE 等指令的伪相关。
    rs1_used = conditional_branch || (ctrl_i.branch_op == BR_JALR) || (ctrl_i.mem_cmd != MEM_NONE)
        || ((ctrl_i.wb_sel == WB_ALU) && (ctrl_i.op_a_sel == OP_A_RS1) &&
            (ctrl_i.alu_op != ALU_PASS_B));
    rs2_used = conditional_branch || (ctrl_i.mem_cmd == MEM_STORE) ||
        ((ctrl_i.wb_sel == WB_ALU) && (ctrl_i.op_b_sel == OP_B_RS2));

    rs1_value_o = rs1_value_i;
    rs2_value_o = rs2_value_i;
    stall_o = 1'b0;

    // 年龄最近的 EX/MEM 写回候选优先于 MEM/WB。匹配但 data_valid
    // 尚未成立时阻塞当前 EX 事务，不能绕过它使用更老的写回值。
    if (rs1_used && (reg_addr_i.rs1_addr != ZeroReg)) begin
      if (ex_wb_req_i.valid && (ex_wb_req_i.rd_addr == reg_addr_i.rs1_addr)) begin
        if (ex_wb_req_i.data_valid) rs1_value_o = ex_wb_req_i.wdata;
        else stall_o = 1'b1;
      end else if (rs1_pending) begin
        stall_o = 1'b1;
      end else if (mem_wb_req_i.valid && (mem_wb_req_i.rd_addr == reg_addr_i.rs1_addr)) begin
        if (mem_wb_req_i.data_valid) rs1_value_o = mem_wb_req_i.wdata;
        else stall_o = 1'b1;
      end
    end

    if (rs2_used && (reg_addr_i.rs2_addr != ZeroReg)) begin
      if (ex_wb_req_i.valid && (ex_wb_req_i.rd_addr == reg_addr_i.rs2_addr)) begin
        if (ex_wb_req_i.data_valid) rs2_value_o = ex_wb_req_i.wdata;
        else stall_o = 1'b1;
      end else if (rs2_pending) begin
        stall_o = 1'b1;
      end else if (mem_wb_req_i.valid && (mem_wb_req_i.rd_addr == reg_addr_i.rs2_addr)) begin
        if (mem_wb_req_i.data_valid) rs2_value_o = mem_wb_req_i.wdata;
        else stall_o = 1'b1;
      end
    end
  end

endmodule
