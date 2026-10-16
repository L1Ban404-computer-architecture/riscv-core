// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 译码、读取 GPR 并生成 ID/EX 事务。IF 异常优先；GPR 数据相关由 EX 前递处理。
module id_stage
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic serialize_block_i,

  // 流水事务
  if_id_if.consumer if_id,
  id_ex_if.producer id_ex,
  gpr_read_if.requester gpr_read
);

  decode_result_t decoded;
  word_t decoded_imm;

  id_ex_payload_t next_payload;
  logic id_ex_input_ready;
  logic input_enable;

  assign gpr_read.req_payload.rs1_addr = decoded.reg_addr.rs1_addr;
  assign gpr_read.req_payload.rs2_addr = decoded.reg_addr.rs2_addr;

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

  // 异常归并与 ID/EX 事务生成

  always_comb begin
    next_payload = '0;
    next_payload.meta = if_id.payload.meta;
    next_payload.reg_addr = decoded.reg_addr;
    next_payload.exec_data.rs1_value = gpr_read.rsp_payload.rs1_value;
    next_payload.exec_data.rs2_value = gpr_read.rsp_payload.rs2_value;
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

  // ID/EX 弹性寄存器

  // 普通 GPR 相关不阻止译码；满载且 EX 就绪允许同拍弹出和写入。
  assign input_enable = !serialize_block_i && !flush_i;
  assign if_id.ready = id_ex_input_ready && input_enable;

  stream_register #(
    .T(id_ex_payload_t)
  ) u_id_ex_register (
    .clk_i,
    .rst_ni,
    .flush_i,
    .valid_i(if_id.valid && input_enable),
    .ready_o(id_ex_input_ready),
    .data_i(next_payload),
    .valid_o(id_ex.valid),
    .ready_i(id_ex.ready),
    .data_o(id_ex.payload)
  );

endmodule
