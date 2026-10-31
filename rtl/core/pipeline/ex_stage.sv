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
  logic data_misaligned;
  exception_payload_t exception;
  pc_t branch_target, pc_plus4, predicted_target_pc;

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

  // 先归并异常，再组装 EX/MEM 事务；异常关闭 GPR 与访存副作用。
  always_comb begin
    case (id_ex.payload.ctrl.mem_size)
      MEM_SIZE_BYTE: data_misaligned = 1'b0;
      MEM_SIZE_HALF: data_misaligned = address[0];
      MEM_SIZE_WORD: data_misaligned = |address[1:0];
      default: data_misaligned = 1'b1;
    endcase

    // 上游异常优先；仅实际跳转时检查指令目标对齐。
    exception = id_ex.payload.exception;
    if (branch_taken && (branch_target[1:0] != 2'b00))
      exception = raise_exception(exception, EXC_INST_ADDR_MISALIGNED, branch_target);
    else if ((id_ex.payload.ctrl.mem_cmd != MEM_NONE) && data_misaligned)
      exception = raise_exception(exception,
          (id_ex.payload.ctrl.mem_cmd == MEM_STORE) ?
              EXC_STORE_ADDR_MISALIGNED : EXC_LOAD_ADDR_MISALIGNED, address);

    result.payload = '{
      commit_ctx: '{
        pc: id_ex.payload.pc,
        gpr: id_ex.payload.gpr,
        value: execution_value,
        exception: exception,
        commit: id_ex.payload.commit
      },
      // value 共用为 GPR 结果、访存地址或 CSR 源；store 数据独立保存。
      mem_req: '{
        valid: (id_ex.payload.ctrl.mem_cmd != MEM_NONE) && !exception.valid,
        write: id_ex.payload.ctrl.mem_cmd == MEM_STORE,
        size: id_ex.payload.ctrl.mem_size,
        sign_ext: id_ex.payload.ctrl.mem_sign_ext,
        wdata: id_ex.payload.exec_data.rs2_value
      }
    };
    if (exception.valid) result.payload.commit_ctx.gpr = '0;
  end

  // 分支计算与异常归并完成后，在 EX 统一生成一次性事件。
  // FENCE.I 的改道和失效由 WB 提交处理。
  assign redirect.valid = id_ex.fire && !exception.valid &&
      !id_ex.payload.commit.fence_i &&
      ((id_ex.payload.prediction.taken != branch_taken) ||
       (branch_taken && !branch_target_match));
  assign redirect.payload = '{
    target_pc: branch_taken ? branch_target : pc_plus4,
    imem_invalidate: 1'b0
  };

  // 训练仅接受 B/J，只检查上游异常及直接目标对齐，保持与访存异常路径独立。
  assign branch_update.valid = id_ex.fire && !id_ex.payload.exception.valid &&
      !(branch_taken && (id_ex.payload.exec_data.direct_target[1:0] != 2'b00)) &&
      (id_ex.payload.ctrl.branch_op inside
          {BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU, BR_JAL});
  assign branch_update.payload = '{
    tag: btb_tag_t'(id_ex.payload.pc >> 2),
    target: id_ex.payload.exec_data.direct_target[BtbTargetWidth-1:1],
    is_jal: id_ex.payload.ctrl.branch_op == BR_JAL,
    taken: branch_taken
  };

`ifndef SYNTHESIS
  assign debug_o = '{
    valid: result.valid, ready: result.ready,
    redirect: redirect.valid,
    branch: '{valid: id_ex.fire && branch_taken && !exception.valid &&
                      (branch_target != pc_plus4),
              target_pc: branch_target}
  };
`endif

endmodule
