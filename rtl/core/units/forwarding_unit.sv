// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// EX 操作数前递与冒险检测。
//
// 为两路源操作数选择最近的可用生产者，并保存阻塞期间短暂出现的写回数据。
// EX/MEM 优先于 MEM/WB；最近生产者尚未给出数据时不得绕过到更老结果；
// 暂存值只属于当前 ID/EX 事务，事务完成或失效时必须清除。
module forwarding_unit
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic transaction_valid_i,
  input logic execute_fire_i,

  // 源操作数
  input reg_addr_t rs1_addr_i,
  input reg_addr_t rs2_addr_i,
  input logic rs1_used_i,
  input logic rs2_used_i,
  input word_t rs1_value_i,
  input word_t rs2_value_i,

  // 前递来源
  writeback_if.consumer ex_wb,
  mem_pending_if.consumer mem_pending,
  writeback_if.consumer mem_wb,

  // 选择结果
  output word_t rs1_value_o,
  output word_t rs2_value_o,
  output logic stall_o
);

  ////////////////////////
  // 内部暂存与相关状态 //
  ////////////////////////

  word_t rs1_base_value;
  word_t rs2_base_value;
  word_t held_rs1_value_q;
  word_t held_rs2_value_q;

  logic rs1_pending;
  logic rs2_pending;
  logic mem_wb_rs1_forwarded;
  logic mem_wb_rs2_forwarded;
  logic held_rs1_valid_q;
  logic held_rs2_valid_q;

  //////////////////////////
  // 前递优先级与阻塞判定 //
  //////////////////////////

  // MEM/WB 可以在当前事务受阻时独立完成写回。已经观察到的前递值必须
  // 保存到该事务执行为止，否则会退回使用 ID/EX 中锁存的旧寄存器值。
  assign rs1_base_value = held_rs1_valid_q ? held_rs1_value_q : rs1_value_i;
  assign rs2_base_value = held_rs2_valid_q ? held_rs2_value_q : rs2_value_i;

  always_comb begin
    rs1_pending = 1'b0;
    rs2_pending = 1'b0;

    rs1_pending = mem_pending.valid &&
        (mem_pending.payload.rd_addr == rs1_addr_i);
    rs2_pending = mem_pending.valid &&
        (mem_pending.payload.rd_addr == rs2_addr_i);
  end

  always_comb begin
    rs1_value_o = rs1_base_value;
    rs2_value_o = rs2_base_value;
    mem_wb_rs1_forwarded = 1'b0;
    mem_wb_rs2_forwarded = 1'b0;
    stall_o = 1'b0;

    // 年龄最近的 EX/MEM 写回候选优先于 MEM/WB。匹配但 data_valid
    // 尚未成立时阻塞当前 EX 事务，不能绕过它使用更老的写回值。
    if (rs1_used_i && (rs1_addr_i != ZeroReg)) begin
      if (ex_wb.payload.valid &&
          (ex_wb.payload.rd_addr == rs1_addr_i)) begin
        if (ex_wb.payload.data_valid) rs1_value_o = ex_wb.payload.wdata;
        else stall_o = 1'b1;
      end else if (rs1_pending) begin
        stall_o = 1'b1;
      end else if (mem_wb.payload.valid &&
                   (mem_wb.payload.rd_addr == rs1_addr_i)) begin
        if (mem_wb.payload.data_valid) begin
          rs1_value_o = mem_wb.payload.wdata;
          mem_wb_rs1_forwarded = 1'b1;
        end else begin
          stall_o = 1'b1;
        end
      end
    end

    if (rs2_used_i && (rs2_addr_i != ZeroReg)) begin
      if (ex_wb.payload.valid &&
          (ex_wb.payload.rd_addr == rs2_addr_i)) begin
        if (ex_wb.payload.data_valid) rs2_value_o = ex_wb.payload.wdata;
        else stall_o = 1'b1;
      end else if (rs2_pending) begin
        stall_o = 1'b1;
      end else if (mem_wb.payload.valid &&
                   (mem_wb.payload.rd_addr == rs2_addr_i)) begin
        if (mem_wb.payload.data_valid) begin
          rs2_value_o = mem_wb.payload.wdata;
          mem_wb_rs2_forwarded = 1'b1;
        end else begin
          stall_o = 1'b1;
        end
      end
    end
  end

  ////////////////////////
  // 阻塞期间的数据暂存 //
  ////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      held_rs1_valid_q <= 1'b0;
      held_rs2_valid_q <= 1'b0;
    end else if (!transaction_valid_i || execute_fire_i) begin
      held_rs1_valid_q <= 1'b0;
      held_rs2_valid_q <= 1'b0;
    end else begin
      if (mem_wb_rs1_forwarded) held_rs1_valid_q <= 1'b1;
      if (mem_wb_rs2_forwarded) held_rs2_valid_q <= 1'b1;
    end
  end

  // 数据位不需要复位；valid=0 时不会被选择，避免为 64 位数据增加复位网络。
  always_ff @(posedge clk_i) begin
    if (transaction_valid_i && !execute_fire_i) begin
      if (mem_wb_rs1_forwarded) held_rs1_value_q <= rs1_value_o;
      if (mem_wb_rs2_forwarded) held_rs2_value_q <= rs2_value_o;
    end
  end

endmodule
