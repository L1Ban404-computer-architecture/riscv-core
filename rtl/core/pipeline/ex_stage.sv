// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "common/assertions.svh"

// 指令执行级。
//
// 完成操作数前递、整数运算、分支判定、访存地址生成和 CSR 读改写计算，
// 并形成包含全部待提交副作用的 EX/MEM 事务。
// 上游异常不可被覆盖；最近生产者尚未给出数据时必须阻塞；串行化指令仅在
// 更老事务排空后执行；所有架构状态仍由 WB 统一提交。
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
  mem_pending_if.consumer mem_pending,
  writeback_if.consumer mem_wb,

  // CSR 与改道
  csr_read_if.requester csr_read,
  redirect_if.producer redirect,

  // 下游事务
  ex_mem_if.producer ex_mem
);

  ////////////////////////
  // 私有类型与内部信号 //
  ////////////////////////

  word_t rs1_value;
  word_t rs2_value;
  word_t operand_a;
  word_t operand_b;
  word_t alu_result;
  word_t pc_plus_4;

  logic forward_stall;
  logic serialize_stall;
  logic ex_execute_fire;
  logic ex_mem_input_valid;
  logic ex_mem_input_ready;

  writeback_payload_t wb_req;
  id_ex_payload_t id_ex_payload;
  ex_mem_payload_t ex_mem_payload;
  writeback_if ex_wb ();
  mem_req_payload_t mem_req;
  ex_mem_payload_t executed_ex_mem_bus;
  redirect_if branch_redirect ();
  exception_payload_t executed_exception;
  commit_ctrl_payload_t commit_ctrl;
  word_t csr_source;
  word_t csr_new_value;
  logic csr_write_attempt;
  logic data_misaligned;
  logic conditional_branch;
  logic rs1_used;
  logic rs2_used;

  ////////////////////////
  // 流水接口解包与打包 //
  ////////////////////////

  assign id_ex_payload = id_ex.payload;
  assign ex_mem.payload = ex_mem_payload;

  always_comb begin
    ex_wb.payload = ex_mem_payload.commit_ctx.wb_req;
    ex_wb.payload.valid = ex_mem.valid && ex_mem_payload.commit_ctx.wb_req.valid;
  end

  //////////////////////////////
  // 数据相关检测与操作数前递 //
  //////////////////////////////

  forwarding_unit u_forwarding_unit (
    .clk_i,
    .rst_ni,
    .transaction_valid_i(id_ex.valid),
    .execute_fire_i(ex_execute_fire),
    .rs1_addr_i(id_ex_payload.reg_addr.rs1_addr),
    .rs2_addr_i(id_ex_payload.reg_addr.rs2_addr),
    .rs1_used_i(rs1_used),
    .rs2_used_i(rs2_used),
    .rs1_value_i(id_ex_payload.exec_data.rs1_value),
    .rs2_value_i(id_ex_payload.exec_data.rs2_value),
    .ex_wb,
    .mem_pending,
    .mem_wb,
    .rs1_value_o(rs1_value),
    .rs2_value_o(rs2_value),
    .stall_o(forward_stall)
  );

  always_comb begin
    conditional_branch = 1'b0;
    case (id_ex_payload.ctrl.branch_op)
      BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU: conditional_branch = 1'b1;
      default: ;
    endcase
    // 只检查指令真正读取的源寄存器，编码中无语义的 rs 字段不会产生
    // LUI、JAL、FENCE 等指令的伪相关。
    rs1_used = conditional_branch || (id_ex_payload.ctrl.branch_op == BR_JALR) ||
        (id_ex_payload.ctrl.mem_cmd != MEM_NONE) ||
        ((id_ex_payload.ctrl.csr_cmd != CSR_NONE) && !id_ex_payload.ctrl.csr_use_imm) ||
        ((id_ex_payload.ctrl.wb_sel == WB_ALU) && (id_ex_payload.ctrl.op_a_sel == OP_A_RS1) &&
         (id_ex_payload.ctrl.alu_op != ALU_PASS_B));
    rs2_used = conditional_branch || (id_ex_payload.ctrl.mem_cmd == MEM_STORE) ||
        ((id_ex_payload.ctrl.wb_sel == WB_ALU) && (id_ex_payload.ctrl.op_b_sel == OP_B_RS2));
  end

  //////////////////////
  // ALU 与控制流执行 //
  //////////////////////

  assign operand_a = (id_ex_payload.ctrl.op_a_sel == OP_A_PC) ? id_ex_payload.meta.pc : rs1_value;
  assign operand_b = (id_ex_payload.ctrl.op_b_sel == OP_B_IMM) ? id_ex_payload.exec_data.imm :
      rs2_value;

  alu u_alu (
    .alu_op_i(id_ex_payload.ctrl.alu_op),
    .operand_a_i(operand_a),
    .operand_b_i(operand_b),
    .result_o(alu_result)
  );

  branch_unit u_branch_unit (
    .execute_fire_i(ex_execute_fire),
    .illegal_instr_i(id_ex_payload.exception.valid),
    .branch_op_i(id_ex_payload.ctrl.branch_op),
    .rs1_value_i(rs1_value),
    .rs2_value_i(rs2_value),
    .alu_target_i(alu_result),
    .redirect(branch_redirect)
  );

  ////////////////////////////
  // CSR 访问与同步异常检测 //
  ////////////////////////////

  assign csr_read.req_payload.addr = id_ex_payload.ctrl.csr_addr;
  assign csr_source = id_ex_payload.ctrl.csr_use_imm ? id_ex_payload.exec_data.imm : rs1_value;
  assign csr_write_attempt = (id_ex_payload.ctrl.csr_cmd == CSR_RW) ||
      (((id_ex_payload.ctrl.csr_cmd == CSR_RS) || (id_ex_payload.ctrl.csr_cmd == CSR_RC)) &&
       (csr_source != '0));

  always_comb begin
    unique case (id_ex_payload.ctrl.mem_size)
      MEM_SIZE_BYTE: data_misaligned = 1'b0;
      MEM_SIZE_HALF: data_misaligned = alu_result[0];
      MEM_SIZE_WORD: data_misaligned = |alu_result[1:0];
      default: data_misaligned = 1'b1;
    endcase

    // 上游异常不可覆盖。EX 仅在当前 payload 尚无异常时补充控制流目标、
    // 数据地址或 CSR 合法性异常，并立即关闭普通 redirect/访存/写回副作用。
    executed_exception = id_ex_payload.exception;
    if (!executed_exception.valid && branch_redirect.valid &&
        (branch_redirect.payload.target_pc[1:0] != 2'b00)) begin
      executed_exception.valid = 1'b1;
      executed_exception.cause = EXC_INST_ADDR_MISALIGNED;
      executed_exception.tval = branch_redirect.payload.target_pc;
    end else if (!executed_exception.valid && (id_ex_payload.ctrl.mem_cmd != MEM_NONE) &&
                 data_misaligned) begin
      executed_exception.valid = 1'b1;
      executed_exception.cause = (id_ex_payload.ctrl.mem_cmd == MEM_STORE) ?
          EXC_STORE_ADDR_MISALIGNED : EXC_LOAD_ADDR_MISALIGNED;
      executed_exception.tval = alu_result;
    end else if (!executed_exception.valid && (id_ex_payload.ctrl.csr_cmd != CSR_NONE) &&
                 (!csr_read.rsp_payload.valid ||
                  (csr_write_attempt && (id_ex_payload.ctrl.csr_addr[11:10] == 2'b11)))) begin
      executed_exception.valid = 1'b1;
      executed_exception.cause = EXC_ILLEGAL_INSTR;
      executed_exception.tval = id_ex_payload.meta.instr;
    end

    redirect.valid = branch_redirect.valid;
    redirect.payload.target_pc = branch_redirect.payload.target_pc;
    // taken 控制流若恰好落到顺序 PC+4，不需要产生多余的前端 flush。
    // 这也统一了退休 debug 的 redirect 语义：只报告下一 PC 的实际改道。
    if (executed_exception.valid ||
        (branch_redirect.valid && (branch_redirect.payload.target_pc == pc_plus_4)))
      redirect.valid = 1'b0;
  end

  assign pc_plus_4 = id_ex_payload.meta.pc + word_t'(4);

  //////////////////////////////
  // 写回、访存与提交事务生成 //
  //////////////////////////////

  always_comb begin
    wb_req = '0;
    wb_req.valid = id_ex_payload.ctrl.rd_write;
    wb_req.rd_addr = id_ex_payload.reg_addr.rd_addr;

    case (id_ex_payload.ctrl.wb_sel)
      WB_NONE: wb_req = '0;
      WB_ALU: begin
        wb_req.data_valid = 1'b1;
        wb_req.wdata = alu_result;
      end
      WB_MEM: begin
        wb_req.data_valid = 1'b0;
        wb_req.wdata = '0;
      end
      WB_PC4: begin
        wb_req.data_valid = 1'b1;
        wb_req.wdata = pc_plus_4;
      end
      WB_CSR: begin
        wb_req.data_valid = 1'b1;
        wb_req.wdata = csr_read.rsp_payload.data;
      end
      default: wb_req = '0;
    endcase

    // x0 写入在这里提前消除，减少后续前递和写回端的无效比较活动。
    if ((wb_req.rd_addr == ZeroReg) || executed_exception.valid) wb_req.valid = 1'b0;
  end

  always_comb begin
    mem_req = '0;
    mem_req.valid = (id_ex_payload.ctrl.mem_cmd != MEM_NONE) && !executed_exception.valid;
    mem_req.write = (id_ex_payload.ctrl.mem_cmd == MEM_STORE);
    mem_req.size = id_ex_payload.ctrl.mem_size;
    mem_req.sign_ext = id_ex_payload.ctrl.mem_sign_ext;
    mem_req.addr = alu_result;
    // 保留未经 lane 对齐的 rs2 数据，移位和 byte enable 生成放在 MEM。
    mem_req.wdata = rs2_value;
  end

  always_comb begin
    unique case (id_ex_payload.ctrl.csr_cmd)
      CSR_RW: csr_new_value = csr_source;
      CSR_RS: csr_new_value = csr_read.rsp_payload.data | csr_source;
      CSR_RC: csr_new_value = csr_read.rsp_payload.data & ~csr_source;
      default: csr_new_value = '0;
    endcase

    // CSR 指令把旧值放入普通 GPR 写回路径，把新值作为提交请求随指令送到 WB。
    // RS/RC 的零源操作数按规范只读，不形成 CSR 写请求。
    commit_ctrl = '0;
    commit_ctrl.serialize = id_ex_payload.ctrl.serialize || executed_exception.valid;
    commit_ctrl.fence_i = id_ex_payload.ctrl.fence_i && !executed_exception.valid;
    commit_ctrl.system_op = id_ex_payload.ctrl.system_op;
    commit_ctrl.csr_write.valid = (id_ex_payload.ctrl.csr_cmd != CSR_NONE) && csr_write_attempt &&
        !executed_exception.valid;
    commit_ctrl.csr_write.addr = id_ex_payload.ctrl.csr_addr;
    commit_ctrl.csr_write.wdata = csr_new_value;
  end

  ///////////////////////////
  // EX/MEM 握手与事务寄存 //
  ///////////////////////////

  // 前递数据未就绪时不允许当前 ID/EX 事务进入 EX/MEM 寄存器。
  // ID 已知的异常与 SYSTEM/CSR 一样，必须先等待所有更老事务排空。
  // 这也避免取指错误携带的无意义指令位影响串行化判断。
  assign serialize_stall = (id_ex_payload.ctrl.serialize || id_ex_payload.exception.valid) &&
      !serialize_ready_i;
  assign ex_mem_input_valid = id_ex.valid && !forward_stall && !serialize_stall && !flush_i;
  assign id_ex.ready = ex_mem_input_ready && !forward_stall && !serialize_stall && !flush_i;
  assign ex_execute_fire = ex_mem_input_valid && ex_mem_input_ready;

  always_comb begin
    executed_ex_mem_bus = '0;
    executed_ex_mem_bus.commit_ctx.meta = id_ex_payload.meta;
    executed_ex_mem_bus.commit_ctx.wb_req = wb_req;
    executed_ex_mem_bus.commit_ctx.exception = executed_exception;
    executed_ex_mem_bus.commit_ctx.commit = commit_ctrl;
    executed_ex_mem_bus.commit_ctx.retire_mem.mem_op = !mem_req.valid ?
        RETIRE_MEM_NONE : (mem_req.write ? RETIRE_MEM_WRITE : RETIRE_MEM_READ);
    executed_ex_mem_bus.commit_ctx.retire_mem.mem_size = mem_req.size;
    executed_ex_mem_bus.commit_ctx.retire_mem.mem_addr = mem_req.addr;
    executed_ex_mem_bus.commit_ctx.retire_mem.mem_data = mem_req.wdata;
    executed_ex_mem_bus.commit_ctx.redirect.valid = redirect.valid;
    executed_ex_mem_bus.commit_ctx.redirect.target_pc = redirect.payload.target_pc;
    executed_ex_mem_bus.mem_req = mem_req;
  end

  // 满载且 MEM 就绪时允许同拍弹出和写入，不在连续指令之间插入气泡。
  stream_register #(
    .T(ex_mem_payload_t)
  ) u_ex_mem_register (
    .clk_i,
    .rst_ni,
    .flush_i,
    .valid_i(ex_mem_input_valid),
    .ready_o(ex_mem_input_ready),
    .data_i(executed_ex_mem_bus),
    .valid_o(ex_mem.valid),
    .ready_i(ex_mem.ready),
    .data_o(ex_mem_payload)
  );

  //////////////
  // 协议断言 //
  //////////////

  // verilog_format: off
  `ASSERT_STABLE(
    ExMemStable,
    ex_mem.valid,
    ex_mem.ready,
    ex_mem_payload,
    ex_mem_payload_t'(0),
    clk_i,
    !rst_ni || flush_i,
    "EX/MEM payload must remain stable while valid is waiting for ready."
  )

  `ASSERT(
    ExMemValidStable,
    ex_mem.valid && !ex_mem.ready |=> ex_mem.valid,
    clk_i,
    !rst_ni || flush_i,
    "EX/MEM valid must remain asserted until ready."
  )
  // verilog_format: on
endmodule
