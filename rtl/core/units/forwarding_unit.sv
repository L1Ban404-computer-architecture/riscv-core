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
  writeback_if.consumer mem_wb,

  // 选择结果
  output word_t rs1_value_o,
  output word_t rs2_value_o,
  output logic stall_o
);

  ////////////////////////
  // 内部暂存与相关状态 //
  ////////////////////////

  typedef struct packed {
    word_t value;
    logic stall;
    logic mem_wb_forwarded;
  } forward_result_t;

  forward_result_t rs1_result, rs2_result;
  word_t rs1_base_value;
  word_t rs2_base_value;
  word_t held_rs1_value_q;
  word_t held_rs2_value_q;

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

  // 最近的 EX/MEM 候选优先；匹配但尚未就绪时，不能绕过到更老的 MEM/WB。
  function automatic forward_result_t resolve_source(
    input logic used,
    input reg_addr_t addr,
    input word_t base_value,
    input writeback_payload_t ex_candidate,
    input writeback_payload_t mem_candidate
  );
    forward_result_t result;
    result = '{value: base_value, stall: 1'b0, mem_wb_forwarded: 1'b0};
    if (used && (addr != ZeroReg)) begin
      if (ex_candidate.valid && (ex_candidate.rd_addr == addr)) begin
        if (ex_candidate.data_valid) result.value = ex_candidate.wdata;
        else result.stall = 1'b1;
      end else if (mem_candidate.valid && (mem_candidate.rd_addr == addr)) begin
        if (mem_candidate.data_valid) begin
          result.value = mem_candidate.wdata;
          result.mem_wb_forwarded = 1'b1;
        end else begin
          result.stall = 1'b1;
        end
      end
    end
    return result;
  endfunction

  assign rs1_result = resolve_source(rs1_used_i, rs1_addr_i, rs1_base_value,
                                     ex_wb.payload, mem_wb.payload);
  assign rs2_result = resolve_source(rs2_used_i, rs2_addr_i, rs2_base_value,
                                     ex_wb.payload, mem_wb.payload);
  assign rs1_value_o = rs1_result.value;
  assign rs2_value_o = rs2_result.value;
  assign mem_wb_rs1_forwarded = rs1_result.mem_wb_forwarded;
  assign mem_wb_rs2_forwarded = rs2_result.mem_wb_forwarded;
  assign stall_o = rs1_result.stall || rs2_result.stall;

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
