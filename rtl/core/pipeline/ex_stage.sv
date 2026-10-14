// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 前递操作数并生成运算结果、访存请求和提交上下文。
// 最近生产者未就绪时停顿；串行化指令等待更老事务排空；架构状态只在 WB 提交。
module ex_stage
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic serialize_ready_i,

  // 流水事务与前递
  id_ex_if.consumer id_ex,
  writeback_if.consumer mem_wb,

  // CSR 与改道
  csr_read_if.requester csr_read,
  redirect_if.producer redirect,

  // 下游事务
  ex_mem_if.producer ex_mem
);

  word_t rs1_value;
  word_t rs2_value;
  word_t operand_a;
  word_t operand_b;
  word_t alu_result;
  word_t pc_plus_4;

  logic forward_stall;
  logic serialize_stall;
  logic input_enable;
  logic ex_mem_input_ready;

  writeback_if ex_wb ();
  commit_context_payload_t next_commit;
  mem_req_payload_t next_mem_req;
  ex_mem_payload_t next_payload;
  redirect_if branch_redirect ();
  exception_payload_t executed_exception;
  word_t csr_source;
  word_t csr_new_value;
  logic csr_write_attempt;
  logic data_misaligned;

  always_comb begin
    ex_wb.payload = ex_mem.payload.commit_ctx.wb_req;
    ex_wb.payload.valid = ex_mem.valid && ex_mem.payload.commit_ctx.wb_req.valid;
  end

  // 数据相关检测与操作数前递

  forwarding_unit u_forwarding_unit (
    .clk_i,
    .rst_ni,
    .transaction_valid_i(id_ex.valid),
    .execute_fire_i(id_ex.fire),
    .rs1_addr_i(id_ex.payload.reg_addr.rs1_addr),
    .rs2_addr_i(id_ex.payload.reg_addr.rs2_addr),
    .rs1_used_i(id_ex.payload.reg_addr.rs1_used),
    .rs2_used_i(id_ex.payload.reg_addr.rs2_used),
    .rs1_value_i(id_ex.payload.exec_data.rs1_value),
    .rs2_value_i(id_ex.payload.exec_data.rs2_value),
    .ex_wb,
    .mem_wb,
    .rs1_value_o(rs1_value),
    .rs2_value_o(rs2_value),
    .stall_o(forward_stall)
  );

  // ALU 与控制流执行

  assign pc_plus_4 = id_ex.payload.meta.pc + word_t'(4);
  assign operand_a = (id_ex.payload.ctrl.op_a_sel == OP_A_PC) ? id_ex.payload.meta.pc : rs1_value;
  assign operand_b = (id_ex.payload.ctrl.op_b_sel == OP_B_IMM) ? id_ex.payload.exec_data.imm :
      rs2_value;

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
    .rs1_value_i(rs1_value),
    .rs2_value_i(rs2_value),
    .alu_target_i(alu_result),
    .redirect(branch_redirect)
  );

  // CSR 访问与同步异常检测

  assign csr_read.req_payload.addr = id_ex.payload.ctrl.csr_addr;
  assign csr_source = id_ex.payload.ctrl.csr_use_imm ? id_ex.payload.exec_data.imm : rs1_value;
  assign csr_write_attempt = (id_ex.payload.ctrl.csr_cmd == CSR_RW) ||
      (((id_ex.payload.ctrl.csr_cmd == CSR_RS) || (id_ex.payload.ctrl.csr_cmd == CSR_RC)) &&
       (csr_source != '0));

  always_comb begin
    unique case (id_ex.payload.ctrl.csr_cmd)
      CSR_RW: csr_new_value = csr_source;
      CSR_RS: csr_new_value = csr_read.rsp_payload.data | csr_source;
      CSR_RC: csr_new_value = csr_read.rsp_payload.data & ~csr_source;
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
    if (branch_redirect.valid && (branch_redirect.payload.target_pc[1:0] != 2'b00)) begin
      executed_exception = raise_exception(executed_exception, EXC_INST_ADDR_MISALIGNED,
                                           branch_redirect.payload.target_pc);
    end else if ((id_ex.payload.ctrl.mem_cmd != MEM_NONE) && data_misaligned) begin
      executed_exception = raise_exception(executed_exception,
                                           (id_ex.payload.ctrl.mem_cmd == MEM_STORE) ?
                                               EXC_STORE_ADDR_MISALIGNED :
                                               EXC_LOAD_ADDR_MISALIGNED, alu_result);
    end else if ((id_ex.payload.ctrl.csr_cmd != CSR_NONE) &&
                 (!csr_read.rsp_payload.valid ||
                  (csr_write_attempt && (id_ex.payload.ctrl.csr_addr[11:10] == 2'b11)))) begin
      executed_exception = raise_exception(executed_exception, EXC_ILLEGAL_INSTR,
                                           id_ex.payload.meta.instr);
    end

    redirect.valid = branch_redirect.valid;
    redirect.payload.target_pc = branch_redirect.payload.target_pc;
    // taken 控制流若恰好落到顺序 PC+4，不需要产生多余的前端 flush。
    // 这也统一了退休 debug 的 redirect 语义：只报告下一 PC 的实际改道。
    if (executed_exception.valid ||
        (branch_redirect.valid && (branch_redirect.payload.target_pc == pc_plus_4)))
      redirect.valid = 1'b0;
  end

  // 写回、访存与提交事务生成

  always_comb begin
    next_commit = '0;
    next_mem_req = '0;
    next_commit.meta.pc = id_ex.payload.meta.pc;
`ifndef SYNTHESIS
    next_commit.meta.instr = id_ex.payload.meta.instr;
    next_commit.meta.instid = id_ex.payload.meta.instid;
`endif
    next_commit.exception = executed_exception;
    next_commit.wb_req.valid = id_ex.payload.ctrl.rd_write;
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
        next_commit.wb_req.wdata = csr_read.rsp_payload.data;
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
    // 保留未经 lane 对齐的 rs2 数据，移位和 byte enable 生成放在 MEM。
    next_mem_req.wdata = rs2_value;

    // CSR 指令把旧值放入普通 GPR 写回路径，把新值作为提交请求随指令送到 WB。
    // RS/RC 的零源操作数按规范只读，不形成 CSR 写请求。
    next_commit.commit.serialize = id_ex.payload.ctrl.serialize || executed_exception.valid;
    next_commit.commit.fence_i = id_ex.payload.ctrl.fence_i && !executed_exception.valid;
    next_commit.commit.system_op = id_ex.payload.ctrl.system_op;
    next_commit.commit.csr_write.valid = (id_ex.payload.ctrl.csr_cmd != CSR_NONE) &&
        csr_write_attempt && !executed_exception.valid;
    next_commit.commit.csr_write.addr = id_ex.payload.ctrl.csr_addr;
    next_commit.commit.csr_write.wdata = csr_new_value;
  end

  assign next_payload = '{commit_ctx: next_commit, mem_req: next_mem_req};

  // EX/MEM 握手与事务寄存

  // 前递数据未就绪时不允许当前 ID/EX 事务进入 EX/MEM 寄存器。
  // ID 已知的异常与 SYSTEM/CSR 一样，必须先等待所有更老事务排空。
  // 这也避免取指错误携带的无意义指令位影响串行化判断。
  assign serialize_stall = (id_ex.payload.ctrl.serialize || id_ex.payload.exception.valid) &&
      !serialize_ready_i;
  assign input_enable = !forward_stall && !serialize_stall && !flush_i;
  assign id_ex.ready = ex_mem_input_ready && input_enable;

  // 满载且 MEM 就绪时允许同拍弹出和写入，不在连续指令之间插入气泡。
  stream_register #(
    .T(ex_mem_payload_t)
  ) u_ex_mem_register (
    .clk_i,
    .rst_ni,
    .flush_i,
    .valid_i(id_ex.valid && input_enable),
    .ready_o(ex_mem_input_ready),
    .data_i(next_payload),
    .valid_o(ex_mem.valid),
    .ready_i(ex_mem.ready),
    .data_o(ex_mem.payload)
  );

endmodule
