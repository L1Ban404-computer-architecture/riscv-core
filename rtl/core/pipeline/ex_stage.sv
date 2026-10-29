// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 使用 ID/EX 中已就绪的操作数，生成运算结果、访存请求和提交上下文。
// FENCE.I 等待更老事务排空；架构状态只在 WB 提交。
module ex_stage
  import riscv_core_pkg::*;
(
  // 已在 ID 完成前递并锁存的流水事务
  id_ex_if.consumer id_ex,
  input logic older_inflight_i,

  // 改道
  redirect_if.producer redirect,
  branch_update_if.producer branch_update,

  // 下游事务
  ex_mem_if.producer result
`ifndef SYNTHESIS
  , output riscv_debug_pkg::execute_debug_payload_t debug_o
`endif
);

  word_t operand_a;
  word_t operand_b;
  word_t alu_result;
  word_t pc_plus_4;

  commit_context_payload_t next_commit;
  mem_req_payload_t next_mem_req;
  logic fence_wait;
  logic branch_taken;
  pc_t branch_target;
  exception_payload_t executed_exception;
  word_t csr_source;
  logic data_misaligned;

  // 等待时同时屏蔽输入 ready 和输出 valid，不能执行或弹出 FENCE.I。
  // CSR 按 WB 顺序读改写，不需要在 EX 等待。
  assign fence_wait = !id_ex.payload.exception.valid && id_ex.payload.ctrl.fence_i &&
      older_inflight_i;
  assign id_ex.ready = result.ready && !fence_wait;
  assign result.valid = id_ex.valid && !fence_wait;

  // ALU 与控制流执行

  assign pc_plus_4 = id_ex.payload.meta.pc + word_t'(4);
  assign operand_a = (id_ex.payload.ctrl.op_a_sel == OP_A_PC) ? id_ex.payload.meta.pc :
      id_ex.payload.exec_data.rs1_value;
  assign operand_b = (id_ex.payload.ctrl.op_b_sel == OP_B_IMM) ? id_ex.payload.exec_data.imm :
      id_ex.payload.exec_data.rs2_value;

  alu u_alu (
    .alu_op_i(id_ex.payload.ctrl.alu_op),
    .operand_a_i(operand_a),
    .operand_b_i(operand_b),
    .result_o(alu_result)
  );

  branch_unit u_branch_unit (
    .branch_op_i(id_ex.payload.ctrl.branch_op),
    .direct_target_i(id_ex.payload.exec_data.direct_target),
    .alu_target_i(alu_result),
    .rs1_value_i(id_ex.payload.exec_data.rs1_value),
    .rs2_value_i(id_ex.payload.exec_data.rs2_value),
    .taken_o(branch_taken),
    .target_pc_o(branch_target)
  );

  // CSR 源操作数与同步异常检测

  assign csr_source = id_ex.payload.ctrl.csr_use_imm ? id_ex.payload.exec_data.imm :
      id_ex.payload.exec_data.rs1_value;

  always_comb begin
    unique case (id_ex.payload.ctrl.mem_size)
      MEM_SIZE_BYTE: data_misaligned = 1'b0;
      MEM_SIZE_HALF: data_misaligned = alu_result[0];
      MEM_SIZE_WORD: data_misaligned = |alu_result[1:0];
      default: data_misaligned = 1'b1;
    endcase

    // 上游异常不可覆盖。EX 仅在当前 payload 尚无异常时补充控制流目标、
    // 数据地址异常，并立即关闭普通 redirect/访存/写回副作用。
    executed_exception = id_ex.payload.exception;
    if (id_ex.fire && branch_taken && (branch_target[1:0] != 2'b00)) begin
      executed_exception = raise_exception(executed_exception, EXC_INST_ADDR_MISALIGNED,
                                           branch_target);
    end else if ((id_ex.payload.ctrl.mem_cmd != MEM_NONE) && data_misaligned) begin
      executed_exception = raise_exception(executed_exception,
                                           (id_ex.payload.ctrl.mem_cmd == MEM_STORE) ?
                                               EXC_STORE_ADDR_MISALIGNED :
                                               EXC_LOAD_ADDR_MISALIGNED, alu_result);
    end
  end

  // 先确定异常，再产生执行事件；异常指令不改道、不训练预测器。
  always_comb begin
    // 核对取指时锁存的方向和目标，不依赖前端当前状态。
    redirect.valid = id_ex.fire && !executed_exception.valid &&
        ((id_ex.payload.meta.prediction.taken != branch_taken) ||
         (branch_taken && (btb_target_pc(id_ex.payload.meta.pc,
             id_ex.payload.meta.prediction.target) != branch_target)));
    redirect.payload = '{
      target_pc: branch_taken ? branch_target : pc_plus_4,
      imem_invalidate: 1'b0
    };

    // fence_wait 已保证更老事务排空；交接成功时触发一次失效和前端重取。
    // FENCE.I 始终重取，独立于普通分支的方向纠错。
    if (id_ex.fire && id_ex.payload.ctrl.fence_i && !executed_exception.valid) begin
      redirect.valid = 1'b1;
      redirect.payload = '{target_pc: pc_plus_4, imem_invalidate: 1'b1};
    end
  end

  // 合法 B/J 不产生访存异常；训练只检查上游异常和实际跳转的目标对齐。
  // 未跳转条件分支仍训练，目标直接使用 ID 快照，不经过 JALR/ALU 路径。
  assign branch_update.valid = id_ex.fire && !id_ex.payload.exception.valid &&
      (id_ex.payload.ctrl.branch_op inside
          {BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU, BR_JAL}) &&
      !(branch_taken && (id_ex.payload.exec_data.direct_target[1:0] != 2'b00));
  assign branch_update.payload = '{
    tag: btb_tag_t'(id_ex.payload.meta.pc >> 2),
    target: id_ex.payload.exec_data.direct_target[BtbTargetWidth-1:1],
    kind: (id_ex.payload.ctrl.branch_op == BR_JAL) ? BTB_JAL : BTB_BRANCH,
    taken: branch_taken
  };

  // 写回、访存与提交事务生成

  always_comb begin
    next_commit = '0;
    next_commit.pc = id_ex.payload.meta.pc;
    next_commit.exception = executed_exception;
    next_commit.gpr.write = id_ex.payload.ctrl.wb_sel != WB_NONE;
    next_commit.gpr.addr = id_ex.payload.reg_addr.rd_addr;
    // 默认保留 ALU 结果，访存指令由 MEM 将它解释为地址。
    next_commit.value = alu_result;

    case (id_ex.payload.ctrl.wb_sel)
      WB_ALU: next_commit.gpr.ready = 1'b1;
      WB_MEM: ;
      WB_PC4: begin
        next_commit.gpr.ready = 1'b1;
        next_commit.value = pc_plus_4;
      end
      WB_CSR: begin
        next_commit.gpr.ready = 1'b0;
        next_commit.value = csr_source;
      end
      default: next_commit.gpr.write = 1'b0;
    endcase

    // x0 写入在这里提前消除，减少后续前递和写回端的无效比较活动。
    if ((next_commit.gpr.addr == ZeroReg) || executed_exception.valid)
      next_commit.gpr.write = 1'b0;

    // CSR 在 WB 执行；这里只有源操作数和紧凑操作信息，不访问架构状态。
    next_commit.commit.is_mret = id_ex.payload.ctrl.system_op == SYS_MRET;
    next_commit.commit.csr = id_ex.payload.ctrl.csr;
  end

  // 访存请求与提交上下文同寿命；rs2 的 lane 对齐由 MEM 完成。
  assign next_mem_req = '{
    valid: (id_ex.payload.ctrl.mem_cmd != MEM_NONE) && !executed_exception.valid,
    write: id_ex.payload.ctrl.mem_cmd == MEM_STORE,
    size: id_ex.payload.ctrl.mem_size,
    sign_ext: id_ex.payload.ctrl.mem_sign_ext,
    wdata: id_ex.payload.exec_data.rs2_value
  };

  assign result.payload = '{commit_ctx: next_commit, mem_req: next_mem_req};

`ifndef SYNTHESIS
  // 流水纠错与架构跳转分别观察，正确预测的分支仍须报告给退休检查器。
  assign debug_o = '{
    valid: result.valid, ready: result.ready,
    redirect: redirect.valid,
    branch: '{valid: id_ex.fire && branch_taken && !executed_exception.valid &&
                      (branch_target != pc_plus_4),
              target_pc: branch_target}
  };
`endif

endmodule
