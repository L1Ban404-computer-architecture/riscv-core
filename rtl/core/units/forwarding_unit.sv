// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 在 ID/EX 前选择操作数：ID/EX 相关等待，EX/MEM > MEM/WB > GPR 实时读值。
// 仅使用寄存后的生产者；最近结果未就绪时反压 ID，不增加流水级。
module forwarding_unit
  import riscv_core_pkg::*;
(
  // 消费译码输出，监视 EX、MEM、WB 的较老生产者。
  id_ex_if.consumer decoded,
  id_ex_if.monitor id_ex,
  ex_mem_if.monitor ex_mem,
  mem_wb_if.monitor mem_wb,

  id_ex_if.producer result
);

  // 前递候选与解析结果

  typedef struct packed {
    word_t value;
    logic stall;
  } forward_result_t;

  forward_result_t rs1_result, rs2_result;
  logic source_stall;
  writeback_payload_t id_ex_candidate;
  writeback_payload_t ex_mem_candidate;
  writeback_payload_t mem_wb_candidate;

  always_comb begin
    // EX 的组合结果不参与前递；即使 EX 暂时不能输出，也必须阻挡相关指令。
    id_ex_candidate = '0;
    id_ex_candidate.valid = id_ex.valid && !id_ex.payload.exception.valid &&
        (id_ex.payload.ctrl.wb_sel != WB_NONE) &&
        (id_ex.payload.reg_addr.rd_addr != ZeroReg);
    id_ex_candidate.rd_addr = id_ex.payload.reg_addr.rd_addr;
    ex_mem_candidate = ex_mem.payload.commit_ctx.wb_req;
    ex_mem_candidate.valid = ex_mem.valid && ex_mem.payload.commit_ctx.wb_req.valid;
    mem_wb_candidate = mem_wb.payload.wb_req;
    mem_wb_candidate.valid = mem_wb.valid && mem_wb.payload.wb_req.valid;
  end

  // 前递优先级与阻塞判定

  // ID 等待时继续读取 GPR，WB 离开后由寄存器堆提供已提交值，无需暂存。
  // 最近候选匹配但未就绪时，不允许绕过到更老的值。
  function automatic forward_result_t resolve_source(
    input logic used,
    input reg_addr_t addr,
    input word_t base_value,
    input writeback_payload_t id_candidate,
    input writeback_payload_t ex_candidate,
    input writeback_payload_t mem_candidate
  );
    forward_result_t result;
    result = '{value: base_value, stall: 1'b0};
    if (used && (addr != ZeroReg)) begin
      if (id_candidate.valid && (id_candidate.rd_addr == addr)) begin
        result.stall = 1'b1;
      end else if (ex_candidate.valid && (ex_candidate.rd_addr == addr)) begin
        if (ex_candidate.data_valid) result.value = ex_candidate.wdata;
        else result.stall = 1'b1;
      end else if (mem_candidate.valid && (mem_candidate.rd_addr == addr)) begin
        if (mem_candidate.data_valid) begin
          result.value = mem_candidate.wdata;
        end else begin
          result.stall = 1'b1;
        end
      end
    end
    return result;
  endfunction

  assign rs1_result = resolve_source(decoded.payload.reg_addr.rs1_used,
      decoded.payload.reg_addr.rs1_addr, decoded.payload.exec_data.rs1_value,
      id_ex_candidate, ex_mem_candidate, mem_wb_candidate);
  assign rs2_result = resolve_source(decoded.payload.reg_addr.rs2_used,
      decoded.payload.reg_addr.rs2_addr, decoded.payload.exec_data.rs2_value,
      id_ex_candidate, ex_mem_candidate, mem_wb_candidate);

  // 仅改写两路源值，其余事务字段组合透传，不增加流水级。
  always_comb begin
    result.payload = decoded.payload;
    result.payload.exec_data.rs1_value = rs1_result.value;
    result.payload.exec_data.rs2_value = rs2_result.value;
  end
  assign source_stall = rs1_result.stall || rs2_result.stall;
  assign result.valid = decoded.valid && !source_stall;
  assign decoded.ready = result.ready && !source_stall;

endmodule
