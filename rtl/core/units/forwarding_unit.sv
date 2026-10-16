// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 选择最近的生产者：EX/MEM > MEM/WB > ID 快照。最近结果未就绪时停顿。
// 阻塞期间保存短暂出现的 MEM/WB 数据，直到当前事务完成或失效。
module forwarding_unit
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 当前执行事务和较老的生产者；候选均来自寄存后的流水边界。
  id_ex_if.monitor id_ex,
  ex_mem_if.monitor ex_mem,
  mem_wb_if.monitor mem_wb,

  execute_operands_if.producer operands
);

  // 内部暂存与相关状态

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

  logic held_rs1_valid_q;
  logic held_rs2_valid_q;
  writeback_payload_t ex_mem_candidate;
  writeback_payload_t mem_wb_candidate;

  always_comb begin
    ex_mem_candidate = ex_mem.payload.commit_ctx.wb_req;
    ex_mem_candidate.valid = ex_mem.valid && ex_mem.payload.commit_ctx.wb_req.valid;
    mem_wb_candidate = mem_wb.payload.wb_req;
    mem_wb_candidate.valid = mem_wb.valid && mem_wb.payload.wb_req.valid;
  end

  // 前递优先级与阻塞判定

  // MEM/WB 可以在当前事务受阻时独立完成写回。已经观察到的前递值必须
  // 保存到该事务执行为止，否则会退回使用 ID/EX 中锁存的旧寄存器值。
  assign rs1_base_value = held_rs1_valid_q ? held_rs1_value_q : id_ex.payload.exec_data.rs1_value;
  assign rs2_base_value = held_rs2_valid_q ? held_rs2_value_q : id_ex.payload.exec_data.rs2_value;

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

  assign rs1_result = resolve_source(id_ex.payload.reg_addr.rs1_used,
      id_ex.payload.reg_addr.rs1_addr, rs1_base_value, ex_mem_candidate, mem_wb_candidate);
  assign rs2_result = resolve_source(id_ex.payload.reg_addr.rs2_used,
      id_ex.payload.reg_addr.rs2_addr, rs2_base_value, ex_mem_candidate, mem_wb_candidate);
  assign operands.rs1_value = rs1_result.value;
  assign operands.rs2_value = rs2_result.value;
  assign operands.stall = rs1_result.stall || rs2_result.stall;

  // 阻塞期间的数据暂存

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      held_rs1_valid_q <= 1'b0;
      held_rs2_valid_q <= 1'b0;
    end else if (!id_ex.valid || id_ex.fire) begin
      held_rs1_valid_q <= 1'b0;
      held_rs2_valid_q <= 1'b0;
    end else begin
      if (rs1_result.mem_wb_forwarded) held_rs1_valid_q <= 1'b1;
      if (rs2_result.mem_wb_forwarded) held_rs2_valid_q <= 1'b1;
    end
  end

  // 数据位不需要复位；valid=0 时不会被选择，避免为 64 位数据增加复位网络。
  always_ff @(posedge clk_i) begin
    if (id_ex.valid && !id_ex.fire) begin
      if (rs1_result.mem_wb_forwarded) held_rs1_value_q <= operands.rs1_value;
      if (rs2_result.mem_wb_forwarded) held_rs2_value_q <= operands.rs2_value;
    end
  end

endmodule
