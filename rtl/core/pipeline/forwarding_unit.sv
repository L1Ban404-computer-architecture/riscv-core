// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 在 ID/EX 前选择操作数：EX > MEM > WB > GPR 实时读值。
// 流水边界标识生产者，阶段输出提供本拍结果；最新结果未就绪时反压 ID。
module forwarding_unit
  import riscv_core_pkg::*;
(
  // 监视 EX/MEM 的输入和输出，区分“生产者存在”和“结果有效”。
  decode_forward_if.consumer decoded,
  id_ex_if.monitor id_ex,
  ex_mem_if.monitor ex_result,
  ex_mem_if.monitor ex_mem,
  mem_wb_if.monitor mem_result,
  gpr_write_if.monitor wb,

  id_ex_if.producer result
);

  typedef struct packed {
    word_t value;
    logic stall;
  } forward_result_t;

  // 前递候选是组合结果，不进入流水寄存器。valid 和 ready 分别表示生产者和数据。
  typedef struct packed {
    logic valid;
    logic ready;
    reg_addr_t addr;
    word_t value;
  } forward_candidate_t;

  forward_result_t rs1_result, rs2_result;
  logic source_stall;
  forward_candidate_t ex_candidate, mem_candidate, wb_candidate;

  always_comb begin
    // ID/EX 始终标识生产者；结果未就绪时不能绕过它选择更老的值。
    // CSR 直到 WB 才返回旧值，EX/MEM 的 value 只是源操作数。
    ex_candidate = '0;
    ex_candidate.valid = id_ex.valid && !id_ex.payload.exception.valid &&
        id_ex.payload.gpr.write;
    ex_candidate.addr = id_ex.payload.gpr.addr;
    ex_candidate.ready = ex_result.valid && ex_result.payload.commit_ctx.gpr.write &&
        ex_result.payload.commit_ctx.gpr.ready;
    ex_candidate.value = ex_result.payload.commit_ctx.value;

    // load 等响应时 mem_result.valid 为 0；相关性始终由 EX/MEM 保留的事务判断。
    mem_candidate.valid = ex_mem.valid && ex_mem.payload.commit_ctx.gpr.write;
    mem_candidate.addr = ex_mem.payload.commit_ctx.gpr.addr;
    mem_candidate.ready = mem_result.valid && mem_result.payload.gpr.write &&
        mem_result.payload.gpr.ready;
    mem_candidate.value = mem_result.payload.value;

    wb_candidate = '{valid: wb.valid, ready: wb.valid,
                     addr: wb.payload.rd_addr, value: wb.payload.wdata};
  end

  // ID 等待时继续读取 GPR，WB 离开后由寄存器堆提供已提交值，无需暂存。
  // 最近候选匹配但未就绪时，不允许绕过到更老的值。
  function automatic forward_result_t resolve_source(
    input logic used,
    input reg_addr_t addr,
    input word_t base_value,
    input forward_candidate_t ex_candidate,
    input forward_candidate_t mem_candidate,
    input forward_candidate_t wb_candidate
  );
    forward_candidate_t candidate;
    forward_result_t result;

    // 先选最近的生产者，再判断数据是否就绪；不能因其未就绪而退回旧值。
    candidate = '0;
    if (ex_candidate.valid && (ex_candidate.addr == addr))
      candidate = ex_candidate;
    else if (mem_candidate.valid && (mem_candidate.addr == addr))
      candidate = mem_candidate;
    else if (wb_candidate.valid && (wb_candidate.addr == addr))
      candidate = wb_candidate;

    result = '{value: base_value, stall: 1'b0};
    if (used && (addr != ZeroReg) && candidate.valid) begin
      if (candidate.ready) result.value = candidate.value;
      else result.stall = 1'b1;
    end
    return result;
  endfunction

  assign rs1_result = resolve_source(decoded.payload.reg_addr.rs1_used,
      decoded.payload.reg_addr.rs1_addr, decoded.payload.instruction.exec_data.rs1_value,
      ex_candidate, mem_candidate, wb_candidate);
  assign rs2_result = resolve_source(decoded.payload.reg_addr.rs2_used,
      decoded.payload.reg_addr.rs2_addr, decoded.payload.instruction.exec_data.rs2_value,
      ex_candidate, mem_candidate, wb_candidate);

  // 仅改写两路源值，其余事务字段组合透传，不增加流水级。
  always_comb begin
    result.payload = decoded.payload.instruction;
    result.payload.exec_data.rs1_value = rs1_result.value;
    result.payload.exec_data.rs2_value = rs2_result.value;
  end
  // 合法性检查与两路相关性比较并行；异常在最后一级绕过停顿，避免先改写
  // rs*_used 再进入前递优先级选择器，也保证异常指令不等待无用的源数据。
  assign source_stall = !decoded.payload.instruction.exception.valid &&
      (rs1_result.stall || rs2_result.stall);
  assign result.valid = decoded.valid && !source_stall;
  assign decoded.ready = result.ready && !source_stall;

endmodule
