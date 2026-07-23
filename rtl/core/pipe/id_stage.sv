// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

`include "common/assertions.svh"

module id_stage (
  input logic clk_i,
  input logic rst_ni,
  // flush 清除所有年轻 ID/EX 事务；serialize_block 阻止年轻指令越过正在执行的
  // CSR/SYSTEM 或已知异常事务。
  input logic flush_i,
  input logic serialize_block_i,

  // IF -> ID 事务通道。ID stage 消费 IF 产生的 fetch/debug 事务，并在内部
  // 完成译码、立即数生成和寄存器堆读取。
  input logic if_id_valid_i,
  output logic if_id_ready_o,
  input if_id_bus_t if_id_bus_i,

  // WB -> ID 写回请求。寄存器堆预计归属 ID stage 内部，因此顶层只把
  // 写回事务送回 ID，不直接暴露寄存器堆端口。
  input wb_req_bus_t wb_req_i,

  // ID -> EX 事务通道。id_ex 的寄存器墙深度初步约束为 1，并由 ID stage
  // 内部维护；EX 只消费该事务，不对它执行 redirect 冲刷。
  output logic id_ex_valid_o,
  input logic id_ex_ready_i,
  output id_ex_bus_t id_ex_bus_o
);

  reg_addr_bus_t decoded_reg_addr;
  imm_type_e decoded_imm_type;
  decode_ctrl_bus_t decoded_ctrl;
  execute_ctrl_bus_t execute_ctrl;
  logic decoded_illegal;
  word_t decoded_imm;
  word_t rs1_value;
  word_t rs2_value;

  id_ex_bus_t decoded_id_ex_bus;
  logic id_ex_input_ready;

  decoder u_decoder (
    .instr_i(if_id_bus_i.instruction.instr),
    .reg_addr_o(decoded_reg_addr),
    .imm_type_o(decoded_imm_type),
    .ctrl_o(decoded_ctrl),
    .illegal_o(decoded_illegal)
  );

  imm_gen u_imm_gen (
    .instr_i(if_id_bus_i.instruction.instr),
    .imm_type_i(decoded_imm_type),
    .imm_o(decoded_imm)
  );

  regfile u_regfile (
    .clk_i,
    .rs1_addr_i(decoded_reg_addr.rs1_addr),
    .rs2_addr_i(decoded_reg_addr.rs2_addr),
    .rs1_value_o(rs1_value),
    .rs2_value_o(rs2_value),
    .wb_req_i
  );

  always_comb begin
    execute_ctrl = '0;
    execute_ctrl.alu_op = decoded_ctrl.alu_op;
    execute_ctrl.op_a_sel = decoded_ctrl.op_a_sel;
    execute_ctrl.op_b_sel = decoded_ctrl.op_b_sel;
    execute_ctrl.branch_op = decoded_ctrl.branch_op;
    execute_ctrl.mem_cmd = decoded_ctrl.mem_cmd;
    execute_ctrl.mem_size = decoded_ctrl.mem_size;
    execute_ctrl.mem_sign_ext = decoded_ctrl.mem_sign_ext;
    execute_ctrl.wb_sel = decoded_ctrl.wb_sel;
    execute_ctrl.rd_write = decoded_ctrl.rd_write;
    execute_ctrl.csr_cmd = decoded_ctrl.csr_cmd;
    execute_ctrl.csr_use_imm = decoded_ctrl.csr_use_imm;
    execute_ctrl.csr_addr = decoded_ctrl.csr_addr;
    execute_ctrl.system_op = decoded_ctrl.system_op;
    execute_ctrl.serialize = decoded_ctrl.serialize;

    decoded_id_ex_bus = '0;
    decoded_id_ex_bus.instruction = if_id_bus_i.instruction;
    decoded_id_ex_bus.reg_addr = decoded_reg_addr;
    decoded_id_ex_bus.exec_data.rs1_value = rs1_value;
    decoded_id_ex_bus.exec_data.rs2_value = rs2_value;
    decoded_id_ex_bus.exec_data.imm = decoded_imm;
    decoded_id_ex_bus.ctrl = execute_ctrl;
    // IF 异常年龄更老且优先。仅在取指正常时，ID 才根据译码补充同步异常。
    decoded_id_ex_bus.exception = if_id_bus_i.exception;
    if (!if_id_bus_i.exception.valid) begin
      if (decoded_illegal) begin
        decoded_id_ex_bus.exception = '0;
        decoded_id_ex_bus.exception.valid = 1'b1;
        decoded_id_ex_bus.exception.cause = EXC_ILLEGAL_INSTR;
        decoded_id_ex_bus.exception.tval = if_id_bus_i.instruction.instr;
      end else if (decoded_ctrl.system_op == SYS_ECALL) begin
        decoded_id_ex_bus.exception = '0;
        decoded_id_ex_bus.exception.valid = 1'b1;
        decoded_id_ex_bus.exception.cause = EXC_ECALL_M;
      end else if (decoded_ctrl.system_op == SYS_EBREAK) begin
        decoded_id_ex_bus.exception = '0;
        decoded_id_ex_bus.exception.valid = 1'b1;
        decoded_id_ex_bus.exception.cause = EXC_BREAKPOINT;
      end
    end
  end

  // 本地 stream_register 实现单入口双向 ready/valid 握手。
  // 它在满载且 EX ready 时允许同拍 pop/push，不会在连续事务间插入气泡。
  assign if_id_ready_o = id_ex_input_ready && !serialize_block_i && !flush_i;

  stream_register #(
    .T(id_ex_bus_t)
  ) u_id_ex_register (
    .clk_i,
    .rst_ni,
    .flush_i,
    .valid_i(if_id_valid_i && !serialize_block_i && !flush_i),
    .ready_o(id_ex_input_ready),
    .data_i(decoded_id_ex_bus),
    .valid_o(id_ex_valid_o),
    .ready_i(id_ex_ready_i),
    .data_o(id_ex_bus_o)
  );

  // verilog_format: off
  `ASSERT_STABLE(
    IdExStable,
    id_ex_valid_o,
    id_ex_ready_i,
    id_ex_bus_o,
    id_ex_bus_t'(0),
    clk_i,
    !rst_ni || flush_i,
    "ID/EX payload must remain stable while valid is waiting for ready."
  )

  `ASSERT(
    IdExValidStable,
    id_ex_valid_o && !id_ex_ready_i |=> id_ex_valid_o,
    clk_i,
    !rst_ni || flush_i,
    "ID/EX valid must remain asserted until ready."
  )
  // verilog_format: on

endmodule
