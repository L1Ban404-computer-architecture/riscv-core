// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 在 ID/EX 前选择操作数：EX > MEM > WB > GPR 实时读值。
// 流水边界标识生产者，阶段输出提供本拍结果；最新结果未就绪时反压 ID。
module forwarding_unit
  import riscv_core_pkg::*;
(
  // 监视 EX/MEM 的输入和输出，区分“生产者存在”和“结果有效”。
  id_ex_if.consumer decoded,
  id_ex_if.monitor id_ex,
  ex_mem_if.monitor ex_result,
  ex_mem_if.monitor ex_mem,
  mem_wb_if.monitor mem_result,
  gpr_write_if.monitor wb,

  id_ex_if.producer result
);

  // 前递候选与解析结果

  typedef struct packed {
    word_t value;
    logic stall;
  } forward_result_t;

  forward_result_t rs1_result, rs2_result;
  logic source_stall;
  writeback_payload_t ex_candidate, mem_candidate, wb_candidate;

  always_comb begin
    // EX 等待串行化或 load 尚未完成时，不能绕过当前生产者取更老的值。
    ex_candidate = '0;
    ex_candidate.valid = id_ex.valid && !id_ex.payload.exception.valid &&
        (id_ex.payload.ctrl.wb_sel != WB_NONE) &&
        (id_ex.payload.reg_addr.rd_addr != ZeroReg);
    ex_candidate.rd_addr = id_ex.payload.reg_addr.rd_addr;
    ex_candidate.data_valid = ex_result.valid && ex_result.payload.commit_ctx.wb_req.valid &&
        ex_result.payload.commit_ctx.wb_req.data_valid;
    ex_candidate.wdata = ex_result.payload.commit_ctx.wb_req.wdata;

    // load 等响应时 mem_result.valid 为 0；相关性始终由 EX/MEM 保留的事务判断。
    mem_candidate = ex_mem.payload.commit_ctx.wb_req;
    mem_candidate.valid = ex_mem.valid && ex_mem.payload.commit_ctx.wb_req.valid;
    mem_candidate.data_valid = mem_result.valid && mem_result.payload.wb_req.valid &&
        mem_result.payload.wb_req.data_valid;
    mem_candidate.wdata = mem_result.payload.wb_req.wdata;

    wb_candidate = '{valid: wb.valid, data_valid: wb.valid,
                     rd_addr: wb.rd_addr, wdata: wb.wdata};
  end

  // 前递优先级与阻塞判定

  // ID 等待时继续读取 GPR，WB 离开后由寄存器堆提供已提交值，无需暂存。
  // 最近候选匹配但未就绪时，不允许绕过到更老的值。
  function automatic forward_result_t resolve_source(
    input logic used,
    input reg_addr_t addr,
    input word_t base_value,
    input writeback_payload_t ex_candidate,
    input writeback_payload_t mem_candidate,
    input writeback_payload_t wb_candidate
  );
    forward_result_t result;
    result = '{value: base_value, stall: 1'b0};
    if (used && (addr != ZeroReg)) begin
      if (ex_candidate.valid && (ex_candidate.rd_addr == addr)) begin
        if (ex_candidate.data_valid) result.value = ex_candidate.wdata;
        else result.stall = 1'b1;
      end else if (mem_candidate.valid && (mem_candidate.rd_addr == addr)) begin
        if (mem_candidate.data_valid) begin
          result.value = mem_candidate.wdata;
        end else begin
          result.stall = 1'b1;
        end
      end else if (wb_candidate.valid && (wb_candidate.rd_addr == addr)) begin
        if (wb_candidate.data_valid) result.value = wb_candidate.wdata;
        else result.stall = 1'b1;
      end
    end
    return result;
  endfunction

  assign rs1_result = resolve_source(decoded.payload.reg_addr.rs1_used,
      decoded.payload.reg_addr.rs1_addr, decoded.payload.exec_data.rs1_value,
      ex_candidate, mem_candidate, wb_candidate);
  assign rs2_result = resolve_source(decoded.payload.reg_addr.rs2_used,
      decoded.payload.reg_addr.rs2_addr, decoded.payload.exec_data.rs2_value,
      ex_candidate, mem_candidate, wb_candidate);

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
