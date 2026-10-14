// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 译码、读取 GPR 并生成 ID/EX 事务。IF 异常优先；屏障只阻止新事务进入。
module id_stage
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
#(
  // 临时 ID 冒险屏障开关；关闭即可恢复仅靠原有 EX 前递/停顿处理数据相关。
  parameter bit EnableTemporaryGprStall = 1'b1
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic serialize_block_i,

  // 流水事务
  if_id_if.consumer if_id,
  id_ex_if.producer id_ex,
  // 临时屏障的观察输入，不改变较老流水级的推进或前递行为。
  ex_mem_if.monitor ex_mem,
  mem_wb_if.monitor mem_wb,
  gpr_read_if.requester gpr_read
);

  decode_result_t decoded;
  word_t decoded_imm;

  id_ex_payload_t next_payload;
  logic id_ex_input_ready;
  logic temporary_gpr_stall;
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

  // 临时逻辑集中在此：停留在 IF/ID，冲突清除后才锁存 GPR 的组合读结果。
  // 只阻止新事务进入 ID/EX，不阻止其中的较老事务排空，避免等待写回时死锁。
  if (EnableTemporaryGprStall) begin : gen_temporary_gpr_stall
    id_gpr_hazard_guard u_id_gpr_hazard_guard (
      .transaction_valid_i(if_id.valid && !next_payload.exception.valid),
      .sources_i(decoded.reg_addr),
      .id_ex_valid_i(id_ex.valid),
      .id_ex_payload_i(id_ex.payload),
      .ex_mem,
      .mem_wb,
      .stall_o(temporary_gpr_stall)
    );
  end else begin : gen_no_temporary_gpr_stall
    assign temporary_gpr_stall = 1'b0;
  end

  // 无串行化或临时 GPR 冲突时，满载且 EX 就绪允许同拍弹出和写入。
  assign input_enable = !serialize_block_i && !flush_i && !temporary_gpr_stall;
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
