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
  word_t alu_result, address, execution_value;
  logic branch_taken, branch_target_match;
  pc_t branch_target, pc_plus4, predicted_target_pc;
  logic is_branch, is_jal;
  logic ras_push, ras_pop, is_return;

  assign id_ex.ready = result.ready;
  assign result.valid = id_ex.valid;
  assign pc_plus4 = id_ex.payload.pc + pc_t'(4);
  // 使用本条指令的 PC 高位还原取指预测快照；这里只拼接位，不做算术。
  assign predicted_target_pc = btb_target_pc(id_ex.payload.pc, id_ex.payload.prediction.target);

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
    .predicted_target_i(predicted_target_pc),
    .is_return_i(is_return),
    .taken_o(branch_taken),
    .target_pc_o(branch_target),
    .target_match_o(branch_target_match)
  );

  // PC+4 在 EX 本地计算；PC 相对结果使用 ID 预计算的目标。
  always_comb begin
    case (id_ex.payload.ctrl.result_source)
      RESULT_ALU: execution_value = alu_result;
      RESULT_PC4: execution_value = pc_plus4;
      RESULT_PC_RELATIVE: execution_value = id_ex.payload.exec_data.direct_target;
      default: execution_value = '0;
    endcase
  end

  execute_result_unit u_execute_result_unit (
    .instruction_i(id_ex.payload),
    .execution_value_i(execution_value),
    .address_i(address),
    .branch_taken_i(branch_taken),
    .branch_target_i(branch_target),
    .result_o(result.payload)
  );

  // 分支计算与异常归并完成后，在 EX 统一生成一次性事件。
  // FENCE.I 的改道和失效由 WB 提交处理。
  assign redirect.valid = id_ex.fire && !result.payload.commit_ctx.exception.valid &&
      !id_ex.payload.commit.fence_i &&
      ((id_ex.payload.prediction.taken != branch_taken) ||
       (branch_taken && !branch_target_match));
  assign redirect.payload = '{
    target_pc: branch_taken ? branch_target : pc_plus4,
    imem_invalidate: 1'b0
  };

  // ID 已归一化 x1/x5 提示；EX 只按最终异常和握手发出一次训练事件。
  assign is_branch = id_ex.payload.ctrl.branch_op inside
      {BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU};
  assign is_jal = id_ex.payload.ctrl.branch_op == BR_JAL;
  assign ras_push = id_ex.payload.ctrl.ras_push;
  assign ras_pop = id_ex.payload.ctrl.ras_pop;
  assign is_return = ras_pop && (id_ex.payload.exec_data.imm == '0);

  // 最终异常统一屏蔽训练；握手才发事件，停顿期间不重复 push/pop。
  assign branch_update.valid = id_ex.fire && !result.payload.commit_ctx.exception.valid &&
      (is_branch || is_jal || ras_push || ras_pop);
  assign branch_update.payload = '{
    tag: btb_tag_t'(id_ex.payload.pc >> 2),
    target: id_ex.payload.exec_data.direct_target[BtbTargetWidth-1:1],
    kind: is_branch ? BTB_BRANCH : is_jal ? BTB_JAL :
          is_return ? BTB_RET : BTB_NONE,
    taken: branch_taken,
    ras_push: ras_push, ras_pop: ras_pop,
    link: pc_plus4[BtbTargetWidth-1:2]
  };

`ifndef SYNTHESIS
  assign debug_o = '{
    valid: result.valid, ready: result.ready,
    redirect: redirect.valid,
    branch: '{valid: id_ex.fire && branch_taken && !result.payload.commit_ctx.exception.valid &&
                      (branch_target != pc_plus4),
              target_pc: branch_target}
  };
`endif

endmodule
