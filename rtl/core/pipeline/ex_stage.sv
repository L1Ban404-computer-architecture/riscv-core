// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 使用前递后的操作数，生成运算结果、访存请求和提交上下文。
// 最近生产者未就绪时停顿；串行化指令等待更老事务排空；架构状态只在 WB 提交。
module ex_stage
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  // 全局控制
  input logic flush_i,
  input logic serialize_ready_i,

  // 流水事务与前递
  id_ex_if.consumer id_ex,
  execute_operands_if.consumer operands,

  // CSR 与改道
  csr_read_if.requester csr_read,
  redirect_if.producer redirect,

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

  logic serialize_stall;
  logic input_enable;

  commit_context_payload_t next_commit;
  mem_req_payload_t next_mem_req;
  ex_mem_payload_t next_payload;
  redirect_if branch_redirect ();
  exception_payload_t executed_exception;
  word_t csr_source;
  word_t csr_new_value;
  logic csr_write_attempt;
  logic data_misaligned;

  // ALU 与控制流执行

  assign pc_plus_4 = id_ex.payload.meta.pc + word_t'(4);
  assign operand_a = (id_ex.payload.ctrl.op_a_sel == OP_A_PC) ? id_ex.payload.meta.pc :
      operands.rs1_value;
  assign operand_b = (id_ex.payload.ctrl.op_b_sel == OP_B_IMM) ? id_ex.payload.exec_data.imm :
      operands.rs2_value;

  alu u_alu (
    .alu_op_i(id_ex.payload.ctrl.alu_op),
    .operand_a_i(operand_a),
    .operand_b_i(operand_b),
    .result_o(alu_result)
  );

  branch_unit u_branch_unit (
    .execute_fire_i(id_ex.fire),
    .illegal_instr_i(id_ex.payload.exception.valid),
    .branch_op_i(id_ex.payload.ctrl.branch_op),
    .rs1_value_i(operands.rs1_value),
    .rs2_value_i(operands.rs2_value),
    .alu_target_i(alu_result),
    .redirect(branch_redirect)
  );

  // CSR 访问与同步异常检测

  assign csr_read.addr = id_ex.payload.ctrl.csr_addr;
  assign csr_source = id_ex.payload.ctrl.csr_use_imm ? id_ex.payload.exec_data.imm :
      operands.rs1_value;
  assign csr_write_attempt = (id_ex.payload.ctrl.csr_cmd == CSR_RW) ||
      (((id_ex.payload.ctrl.csr_cmd == CSR_RS) || (id_ex.payload.ctrl.csr_cmd == CSR_RC)) &&
       (csr_source != '0));

  always_comb begin
    unique case (id_ex.payload.ctrl.csr_cmd)
      CSR_RW: csr_new_value = csr_source;
      CSR_RS: csr_new_value = csr_read.data | csr_source;
      CSR_RC: csr_new_value = csr_read.data & ~csr_source;
      default: csr_new_value = '0;
    endcase
  end

  always_comb begin
    unique case (id_ex.payload.ctrl.mem_size)
      MEM_SIZE_BYTE: data_misaligned = 1'b0;
      MEM_SIZE_HALF: data_misaligned = alu_result[0];
      MEM_SIZE_WORD: data_misaligned = |alu_result[1:0];
      default: data_misaligned = 1'b1;
    endcase

    // 上游异常不可覆盖。EX 仅在当前 payload 尚无异常时补充控制流目标、
    // 数据地址或 CSR 合法性异常，并立即关闭普通 redirect/访存/写回副作用。
    executed_exception = id_ex.payload.exception;
    if (branch_redirect.valid && (branch_redirect.target_pc[1:0] != 2'b00)) begin
      executed_exception = raise_exception(executed_exception, EXC_INST_ADDR_MISALIGNED,
                                           branch_redirect.target_pc);
    end else if ((id_ex.payload.ctrl.mem_cmd != MEM_NONE) && data_misaligned) begin
      executed_exception = raise_exception(executed_exception,
                                           (id_ex.payload.ctrl.mem_cmd == MEM_STORE) ?
                                               EXC_STORE_ADDR_MISALIGNED :
                                               EXC_LOAD_ADDR_MISALIGNED, alu_result);
    end else if ((id_ex.payload.ctrl.csr_cmd != CSR_NONE) &&
                 (!csr_read.implemented ||
                  (csr_write_attempt && (id_ex.payload.ctrl.csr_addr[11:10] == 2'b11)))) begin
      executed_exception = raise_exception(executed_exception, EXC_ILLEGAL_INSTR,
                                           id_ex.payload.meta.instr);
    end

    redirect.valid = branch_redirect.valid;
    redirect.target_pc = branch_redirect.target_pc;
    // taken 控制流若恰好落到顺序 PC+4，不需要产生多余的前端 flush。
    if (executed_exception.valid ||
        (branch_redirect.valid && (branch_redirect.target_pc == pc_plus_4)))
      redirect.valid = 1'b0;
  end

  // 写回、访存与提交事务生成

  always_comb begin
    next_commit = '0;
    next_mem_req = '0;
    next_commit.pc = id_ex.payload.meta.pc;
    next_commit.exception = executed_exception;
    next_commit.wb_req.valid = id_ex.payload.ctrl.wb_sel != WB_NONE;
    next_commit.wb_req.rd_addr = id_ex.payload.reg_addr.rd_addr;

    case (id_ex.payload.ctrl.wb_sel)
      WB_NONE: next_commit.wb_req = '0;
      WB_ALU: begin
        next_commit.wb_req.data_valid = 1'b1;
        next_commit.wb_req.wdata = alu_result;
      end
      WB_MEM: begin
        next_commit.wb_req.data_valid = 1'b0;
        next_commit.wb_req.wdata = '0;
      end
      WB_PC4: begin
        next_commit.wb_req.data_valid = 1'b1;
        next_commit.wb_req.wdata = pc_plus_4;
      end
      WB_CSR: begin
        next_commit.wb_req.data_valid = 1'b1;
        next_commit.wb_req.wdata = csr_read.data;
      end
      default: next_commit.wb_req = '0;
    endcase

    // x0 写入在这里提前消除，减少后续前递和写回端的无效比较活动。
    if ((next_commit.wb_req.rd_addr == ZeroReg) || executed_exception.valid)
      next_commit.wb_req.valid = 1'b0;

    next_mem_req.valid = (id_ex.payload.ctrl.mem_cmd != MEM_NONE) && !executed_exception.valid;
    next_mem_req.write = (id_ex.payload.ctrl.mem_cmd == MEM_STORE);
    next_mem_req.size = id_ex.payload.ctrl.mem_size;
    next_mem_req.sign_ext = id_ex.payload.ctrl.mem_sign_ext;
    next_mem_req.addr = alu_result;
    // 保留未经 lane 对齐的 rs2 数据，移位放在 MEM，写掩码由总线适配器生成。
    next_mem_req.wdata = operands.rs2_value;

    // CSR 指令把旧值放入普通 GPR 写回路径，把新值作为提交请求随指令送到 WB。
    // RS/RC 的零源操作数按规范只读，不形成 CSR 写请求。
    next_commit.commit.serialize = id_ex.payload.ctrl.serialize || executed_exception.valid;
    next_commit.commit.fence_i = id_ex.payload.ctrl.fence_i && !executed_exception.valid;
    next_commit.commit.is_mret = id_ex.payload.ctrl.system_op == SYS_MRET;
    next_commit.commit.csr_write.valid = (id_ex.payload.ctrl.csr_cmd != CSR_NONE) &&
        csr_write_attempt && !executed_exception.valid;
    next_commit.commit.csr_write.addr = id_ex.payload.ctrl.csr_addr;
    next_commit.commit.csr_write.wdata = csr_new_value;
  end

  assign next_payload = '{commit_ctx: next_commit, mem_req: next_mem_req};

  // 本级握手；EX/MEM 寄存器由顶层持有。

  // 前递数据未就绪时不允许当前 ID/EX 事务进入 EX/MEM 寄存器。
  // ID 已知的异常与 SYSTEM/CSR 一样，必须先等待所有更老事务排空。
  // 这也避免取指错误携带的无意义指令位影响串行化判断。
  assign serialize_stall = (id_ex.payload.ctrl.serialize || id_ex.payload.exception.valid) &&
      !serialize_ready_i;
  assign input_enable = !operands.stall && !serialize_stall && !flush_i;
  assign id_ex.ready = result.ready && input_enable;

  assign result.valid = id_ex.valid && input_enable;
  assign result.payload = next_payload;

`ifndef SYNTHESIS
  assign debug_o = '{
    valid: id_ex.valid, ready: id_ex.ready,
    redirect: '{valid: redirect.valid, target_pc: redirect.target_pc}
  };
`endif

endmodule
