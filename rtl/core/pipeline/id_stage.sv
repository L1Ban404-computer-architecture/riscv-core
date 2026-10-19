// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 译码、读取 GPR 并生成 ID/EX 事务。IF 异常优先；输出先经前递再锁存。
module id_stage
  import riscv_core_pkg::*;
(
  // 流水事务
  if_id_if.consumer if_id,
  id_ex_if.producer result,
  gpr_read_if.requester gpr_read
`ifndef SYNTHESIS
  , output riscv_debug_pkg::stage_debug_payload_t debug_o
`endif
);

  decode_result_t decoded;
  word_t decoded_imm;
  id_ex_payload_t next_payload;

  // 译码、立即数与寄存器读取
  decoder u_decoder (
    .instr_i(if_id.payload.meta.instr),
    .decode_o(decoded)
  );

  imm_gen u_imm_gen (
    .instr_i(if_id.payload.meta.instr[31:7]),
    .imm_type_i(decoded.imm_type),
    .imm_o(decoded_imm)
  );

  assign gpr_read.rs1_addr = decoded.reg_addr.rs1_addr;
  assign gpr_read.rs2_addr = decoded.reg_addr.rs2_addr;

  // 异常归并与 ID/EX 事务生成
  always_comb begin
    next_payload = '0;
    next_payload.meta = if_id.payload.meta;
    next_payload.reg_addr = decoded.reg_addr;
    next_payload.exec_data.rs1_value = gpr_read.rs1_value;
    next_payload.exec_data.rs2_value = gpr_read.rs2_value;
    next_payload.exec_data.imm = decoded_imm;
    next_payload.ctrl = decoded.ctrl;
    // IF 异常年龄更老且优先。raise_exception 在已有 valid 时保持原样。
    next_payload.exception = if_id.payload.exception;
    if (decoded.illegal) begin
      next_payload.exception =
          raise_exception(next_payload.exception, EXC_ILLEGAL_INSTR, if_id.payload.meta.instr);
    end else if (decoded.ctrl.system_op == SYS_ECALL) begin
      next_payload.exception =
          raise_exception(next_payload.exception, EXC_ECALL_M, '0);
    end else if (decoded.ctrl.system_op == SYS_EBREAK) begin
      next_payload.exception =
          raise_exception(next_payload.exception, EXC_BREAKPOINT, '0);
    end
  end

  // GPR 相关通过前递单元的 ready 反压；等待期间继续读取寄存器堆。
  // IF/ID 已在改道当拍屏蔽旧事务；串行化等待通过普通 ready 反压传回。
  assign if_id.ready = result.ready;
  assign result.valid = if_id.valid;
  assign result.payload = next_payload;

`ifndef SYNTHESIS
  assign debug_o = '{valid: if_id.valid, ready: if_id.ready};
`endif

endmodule
