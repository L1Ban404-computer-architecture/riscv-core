// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 译码、读取 GPR 并生成 ID/EX 事务。IF 异常优先；输出先经前递再锁存。
module id_stage
  import riscv_core_pkg::*;
(
  // 流水事务
  if_id_if.consumer if_id,
  id_ex_if.producer result,
  output reg_addr_payload_t source_regs_o,
  gpr_read_if.requester gpr_read
`ifndef SYNTHESIS
  , output riscv_debug_pkg::stage_debug_payload_t debug_o
`endif
);

  decode_result_t decoded;
  word_t immediate;

  // 译码、立即数与寄存器读取
  decoder u_decoder (
    .instr_i(if_id.payload.meta.instr),
    .decode_o(decoded)
  );

  imm_gen u_imm_gen (
    .instr_i(if_id.payload.meta.instr),
    .imm_o(immediate)
  );

  assign gpr_read.rs1_addr = decoded.reg_addr.rs1_addr;
  assign gpr_read.rs2_addr = decoded.reg_addr.rs2_addr;
  assign source_regs_o = decoded.reg_addr;

  // 异常归并与 ID/EX 事务生成
  always_comb begin
    result.payload = '0;
    result.payload.pc = if_id.payload.meta.pc;
    result.payload.gpr = decoded.gpr;
    result.payload.prediction = if_id.payload.meta.prediction;
    result.payload.exec_data = '{
      rs1_value: gpr_read.rs1_value, rs2_value: gpr_read.rs2_value, imm: immediate,
      // AUIPC/B/J 共用立即数计算 PC 相对结果；锁存后 EX 无需重新相加。
      direct_target: if_id.payload.meta.pc + immediate
    };
    result.payload.ctrl = decoded.ctrl;
    result.payload.commit = decoded.commit;
    // 优先保留 IF 的访问异常；只有取指成功后才解释译码异常。
    result.payload.exception = if_id.payload.exception;
    if (decoded.illegal) begin
      result.payload.exception =
          raise_exception(result.payload.exception, EXC_ILLEGAL_INSTR, if_id.payload.meta.instr);
    end else if (decoded.system_op == SYS_ECALL) begin
      result.payload.exception = raise_exception(result.payload.exception, EXC_ECALL_M, '0);
    end else if (decoded.system_op == SYS_EBREAK) begin
      result.payload.exception = raise_exception(result.payload.exception, EXC_BREAKPOINT, '0);
    end
    // 异常不作为 GPR 生产者，前递单元直接放行异常。
    if (result.payload.exception.valid || (decoded.gpr.addr == ZeroReg))
      result.payload.gpr = '0;
  end

  // GPR 相关通过前递单元的 ready 反压；等待期间继续读取寄存器堆。
  // 取指侧已在改道当拍屏蔽旧事务；EX 等待通过普通 ready 反压传回。
  assign if_id.ready = result.ready;
  assign result.valid = if_id.valid;

`ifndef SYNTHESIS
  assign debug_o = '{valid: if_id.valid, ready: if_id.ready};
`endif

endmodule
