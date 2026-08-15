// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "common/assertions.svh"

// 指令译码级。
//
// 解析 RV32 指令，生成立即数，读取通用寄存器，并形成 ID/EX 事务。
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
  writeback_if.consumer wb,
  id_ex_if.producer id_ex
);

  ////////////////////////
  // 私有类型与内部信号 //
  ////////////////////////

  decode_result_t decoded;
  if_id_payload_t if_id_payload;
  id_ex_payload_t id_ex_payload;
  word_t decoded_imm;
  word_t rs1_value;
  word_t rs2_value;

  id_ex_payload_t decoded_id_ex_bus;
  logic id_ex_input_ready;

  assign if_id_payload = if_id.payload;
  assign id_ex.payload = id_ex_payload;

  //////////////////////////////
  // 译码、立即数与寄存器读取 //
  //////////////////////////////

  decoder u_decoder (
    .instr_i(if_id_payload.instr),
    .decode_o(decoded)
  );

  imm_gen u_imm_gen (
    .instr_i(if_id_payload.instr[31:7]),
    .imm_type_i(decoded.imm_type),
    .imm_o(decoded_imm)
  );

  regfile u_regfile (
    .clk_i,
    .rs1_addr_i(decoded.reg_addr.rs1_addr),
    .rs2_addr_i(decoded.reg_addr.rs2_addr),
    .rs1_value_o(rs1_value),
    .rs2_value_o(rs2_value),
    .wb
  );

  ///////////////////////////////
  // 异常归并与 ID/EX 事务生成 //
  ///////////////////////////////

  always_comb begin
    decoded_id_ex_bus = '0;
    decoded_id_ex_bus.pc = if_id_payload.pc;
    decoded_id_ex_bus.instr = if_id_payload.instr;
    decoded_id_ex_bus.reg_addr = decoded.reg_addr;
    decoded_id_ex_bus.exec_data.rs1_value = rs1_value;
    decoded_id_ex_bus.exec_data.rs2_value = rs2_value;
    decoded_id_ex_bus.exec_data.imm = decoded_imm;
    decoded_id_ex_bus.ctrl = decoded.ctrl;
    decoded_id_ex_bus.debug = if_id_payload.debug;
    // IF 异常年龄更老且优先。仅在取指正常时，ID 才根据译码补充同步异常。
    decoded_id_ex_bus.exception = if_id_payload.exception;
    if (!if_id_payload.exception.valid) begin
      if (decoded.illegal) begin
        decoded_id_ex_bus.exception = '0;
        decoded_id_ex_bus.exception.valid = 1'b1;
        decoded_id_ex_bus.exception.cause = EXC_ILLEGAL_INSTR;
        decoded_id_ex_bus.exception.tval = if_id_payload.instr;
      end else if (decoded.ctrl.system_op == SYS_ECALL) begin
        decoded_id_ex_bus.exception = '0;
        decoded_id_ex_bus.exception.valid = 1'b1;
        decoded_id_ex_bus.exception.cause = EXC_ECALL_M;
      end else if (decoded.ctrl.system_op == SYS_EBREAK) begin
        decoded_id_ex_bus.exception = '0;
        decoded_id_ex_bus.exception.valid = 1'b1;
        decoded_id_ex_bus.exception.cause = EXC_BREAKPOINT;
      end
    end
  end

  //////////////////////
  // ID/EX 弹性寄存器 //
  //////////////////////

  // 满载且 EX 就绪时允许同拍弹出和写入，不在连续事务间插入气泡。
  assign if_id.ready = id_ex_input_ready && !serialize_block_i && !flush_i;

  stream_register #(
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

  //////////////
  // 协议断言 //
  //////////////

  // verilog_format: off
  `ASSERT_STABLE(
    IdExStable,
    id_ex.valid,
    id_ex.ready,
    id_ex_payload,
    id_ex_payload_t'(0),
    clk_i,
    !rst_ni || flush_i,
    "ID/EX payload must remain stable while valid is waiting for ready."
  )

  `ASSERT(
    IdExValidStable,
    id_ex.valid && !id_ex.ready |=> id_ex.valid,
    clk_i,
    !rst_ni || flush_i,
    "ID/EX valid must remain asserted until ready."
  )
  // verilog_format: on

endmodule
