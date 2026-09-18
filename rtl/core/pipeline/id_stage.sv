// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 指令译码级。
//
// 解析 RV32 指令，生成立即数，经 gpr_read_if 读取寄存器，并形成 ID/EX 事务。
// IF 已报告的异常优先于本级异常；冲刷或串行化阻塞期间不得接收新事务；
// ID/EX 边界必须满足标准 ready/valid 保持规则。
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

  ////////////////////////
  // 私有类型与内部信号 //
  ////////////////////////

  decode_result_t decoded;
  if_id_payload_t if_id_payload;
  id_ex_payload_t id_ex_payload;
  word_t decoded_imm;

  id_ex_payload_t decoded_id_ex_bus;
  logic id_ex_input_ready;

  assign if_id_payload = if_id.payload;
  assign id_ex.payload = id_ex_payload;
  assign gpr_read.req_payload.rs1_addr = decoded.reg_addr.rs1_addr;
  assign gpr_read.req_payload.rs2_addr = decoded.reg_addr.rs2_addr;

  //////////////////////////////
  // 译码、立即数与寄存器读取 //
  //////////////////////////////

  decoder u_decoder (
    .instr_i(if_id_payload.meta.instr),
    .decode_o(decoded)
  );

  imm_gen u_imm_gen (
    .instr_i(if_id_payload.meta.instr[31:7]),
    .imm_type_i(decoded.imm_type),
    .imm_o(decoded_imm)
  );

  ///////////////////////////////
  // 异常归并与 ID/EX 事务生成 //
  ///////////////////////////////

  always_comb begin
    decoded_id_ex_bus = '0;
    decoded_id_ex_bus.meta = if_id_payload.meta;
    decoded_id_ex_bus.reg_addr = decoded.reg_addr;
    decoded_id_ex_bus.exec_data.rs1_value = gpr_read.rsp_payload.rs1_value;
    decoded_id_ex_bus.exec_data.rs2_value = gpr_read.rsp_payload.rs2_value;
    decoded_id_ex_bus.exec_data.imm = decoded_imm;
    decoded_id_ex_bus.ctrl = decoded.ctrl;
    // IF 异常年龄更老且优先。raise_exception 在已有 valid 时保持原样。
    decoded_id_ex_bus.exception = if_id_payload.exception;
    if (decoded.illegal) begin
      decoded_id_ex_bus.exception =
          raise_exception(decoded_id_ex_bus.exception, EXC_ILLEGAL_INSTR, if_id_payload.meta.instr);
    end else if (decoded.ctrl.system_op == SYS_ECALL) begin
      decoded_id_ex_bus.exception =
          raise_exception(decoded_id_ex_bus.exception, EXC_ECALL_M, '0);
    end else if (decoded.ctrl.system_op == SYS_EBREAK) begin
      decoded_id_ex_bus.exception =
          raise_exception(decoded_id_ex_bus.exception, EXC_BREAKPOINT, '0);
    end
  end

  //////////////////////
  // ID/EX 弹性寄存器 //
  //////////////////////

  // 满载且 EX 就绪时允许同拍弹出和写入，不在连续事务间插入气泡。
  assign if_id.ready = id_ex_input_ready && !serialize_block_i && !flush_i;

  pipeline_register #(
    .T(id_ex_payload_t)
  ) u_id_ex_register (
    .clk_i,
    .rst_ni,
    .flush_i,
    .valid_i(if_id.valid && !serialize_block_i && !flush_i),
    .ready_o(id_ex_input_ready),
    .data_i(decoded_id_ex_bus),
    .valid_o(id_ex.valid),
    .ready_i(id_ex.ready),
    .data_o(id_ex_payload)
  );

endmodule
