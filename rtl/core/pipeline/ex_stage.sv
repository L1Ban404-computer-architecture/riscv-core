// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 消费已前递的 rs1/rs2/imm，生成执行结果、访存请求和提交上下文。
// 此处选择数据并连接运算、控制流和执行完成事务，不读取架构状态。
module ex_stage
  import riscv_core_pkg::*;
(
  id_ex_if.consumer id_ex,
  redirect_if.producer redirect,
  branch_update_if.producer branch_update,
  ex_mem_if.producer result
`ifndef SYNTHESIS
  , output riscv_debug_pkg::execute_debug_payload_t debug_o
`endif
);

  word_t operand_b;
  word_t alu_result, address, value;
  logic branch_taken;
  pc_t branch_target;

  assign id_ex.ready = result.ready;
  assign result.valid = id_ex.valid;

  // A 始终为 rs1；ID/EX 保留 rs2 与立即数，在 EX 选择 B。
  assign operand_b = (id_ex.payload.ctrl.op_b_sel == OP_B_IMM) ?
      id_ex.payload.exec_data.imm : id_ex.payload.exec_data.rs2_value;

  alu u_alu (
    .op_i(id_ex.payload.ctrl.alu_op),
    .operand_a_i(id_ex.payload.exec_data.rs1_value),
    .operand_b_i(operand_b),
    .result_o(alu_result),
    .address_o(address)
  );

  branch_unit u_branch_unit (
    .branch_op_i(id_ex.payload.ctrl.branch_op),
    .direct_target_i(id_ex.payload.exec_data.direct_target),
    .alu_target_i(address),
    .rs1_value_i(id_ex.payload.exec_data.rs1_value),
    .rs2_value_i(id_ex.payload.exec_data.rs2_value),
    .imm_i(id_ex.payload.exec_data.imm),
    .pc_plus4_i(id_ex.payload.exec_data.pc_plus4),
    .prediction_i(id_ex.payload.prediction),
    .fence_i(id_ex.payload.commit.fence_i),
    .fire_i(id_ex.fire),
    .upstream_exception_valid_i(id_ex.payload.exception.valid),
    .exception_valid_i(result.payload.commit_ctx.exception.valid),
    .taken_o(branch_taken),
    .target_pc_o(branch_target),
    .redirect,
    .branch_update
  );

  // ALU 完成全部整数运算，EX 只选择普通结果或 ID 预计算的 PC 结果。
  always_comb begin
    case (id_ex.payload.ctrl.result_source)
      RESULT_ALU: value = alu_result;
      RESULT_PC4: value = id_ex.payload.exec_data.pc_plus4;
      RESULT_PC_RELATIVE: value = id_ex.payload.exec_data.direct_target;
      default: value = '0;
    endcase
  end

  execute_result_unit u_execute_result_unit (
    .instruction_i(id_ex.payload),
    .value_i(value),
    .address_i(address),
    .branch_taken_i(branch_taken),
    .branch_target_i(branch_target),
    .result_o(result.payload)
  );

`ifndef SYNTHESIS
  assign debug_o = '{
    valid: result.valid, ready: result.ready,
    redirect: redirect.valid,
    branch: '{valid: id_ex.fire && branch_taken && !result.payload.commit_ctx.exception.valid &&
                      (branch_target != id_ex.payload.exec_data.pc_plus4),
              target_pc: branch_target}
  };
`endif

endmodule
