// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

`include "common/assertions.svh"

module ex_stage (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic serialize_ready_i,

  // ID -> EX 事务通道。进入 EX 的指令被视为已确认有效，不再被 redirect
  // 冲刷；若数据前递不可用，EX 通过 id_ex_ready_o 反压 ID。
  input logic id_ex_valid_i,
  output logic id_ex_ready_o,
  input id_ex_bus_t id_ex_bus_i,

  // MEM outstanding load 以及 MEM/WB 写回候选。另一路年龄最近的 EX/MEM
  // 候选由本 stage 内部保存。
  input wb_req_bus_t mem_pending_wb_req_i,
  input wb_req_bus_t mem_wb_req_i,

  output csr_addr_t csr_read_addr_o,
  input csr_read_rsp_bus_t csr_read_rsp_i,

  // EX -> IF redirect。该信号单向指向前端，只影响更年轻的 IF/ID 事务。
  output redirect_bus_t redirect_o,

  // EX -> MEM 事务通道。EX 负责形成访存请求、写回候选和 EX debug 信息。
  output logic ex_mem_valid_o,
  input logic ex_mem_ready_i,
  output ex_mem_bus_t ex_mem_bus_o
);

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

  wb_req_bus_t wb_req;
  wb_req_bus_t ex_mem_wb_req;
  mem_req_bus_t mem_req;
  ex_mem_bus_t executed_ex_mem_bus;
  redirect_bus_t branch_redirect;
  exception_bus_t executed_exception;
  commit_ctrl_bus_t commit_ctrl;
  word_t csr_source;
  word_t csr_new_value;
  logic data_misaligned;

  always_comb begin
    ex_mem_wb_req = ex_mem_bus_o.wb_req;
    ex_mem_wb_req.valid = ex_mem_valid_o && ex_mem_bus_o.wb_req.valid;
  end

  forwarding_unit u_forwarding_unit (
    .clk_i,
    .rst_ni,
    .transaction_valid_i(id_ex_valid_i),
    .execute_fire_i(ex_execute_fire),
    .reg_addr_i(id_ex_bus_i.reg_addr),
    .rs1_value_i(id_ex_bus_i.exec_data.rs1_value),
    .rs2_value_i(id_ex_bus_i.exec_data.rs2_value),
    .ctrl_i(id_ex_bus_i.ctrl),
    .ex_wb_req_i(ex_mem_wb_req),
    .mem_pending_wb_req_i,
    .mem_wb_req_i,
    .rs1_value_o(rs1_value),
    .rs2_value_o(rs2_value),
    .stall_o(forward_stall)
  );

  assign operand_a = (id_ex_bus_i.ctrl.op_a_sel == OP_A_PC) ?
      id_ex_bus_i.instruction.pc : rs1_value;
  assign
      operand_b = (id_ex_bus_i.ctrl.op_b_sel == OP_B_IMM) ? id_ex_bus_i.exec_data.imm : rs2_value;

  alu u_alu (
    .alu_op_i(id_ex_bus_i.ctrl.alu_op),
    .operand_a_i(operand_a),
    .operand_b_i(operand_b),
    .result_o(alu_result)
  );

  branch_unit u_branch_unit (
    .execute_fire_i(ex_execute_fire),
    .illegal_instr_i(id_ex_bus_i.exception.valid),
    .branch_op_i(id_ex_bus_i.ctrl.branch_op),
    .rs1_value_i(rs1_value),
    .rs2_value_i(rs2_value),
    .alu_target_i(alu_result),
    .redirect_o(branch_redirect)
  );

  assign csr_read_addr_o = id_ex_bus_i.ctrl.csr_addr;
  assign csr_source = id_ex_bus_i.ctrl.csr_use_imm ? id_ex_bus_i.exec_data.imm : rs1_value;

  always_comb begin
    unique case (id_ex_bus_i.ctrl.mem_size)
      MEM_SIZE_BYTE: data_misaligned = 1'b0;
      MEM_SIZE_HALF: data_misaligned = alu_result[0];
      MEM_SIZE_WORD: data_misaligned = |alu_result[1:0];
      default: data_misaligned = 1'b1;
    endcase

    // 上游异常不可覆盖。EX 仅在当前 payload 尚无异常时补充控制流目标、
    // 数据地址或 CSR 合法性异常，并立即关闭普通 redirect/访存/写回副作用。
    executed_exception = id_ex_bus_i.exception;
    if (!executed_exception.valid && branch_redirect.valid &&
                 (branch_redirect.target_pc[1:0] != 2'b00)) begin
      executed_exception.valid = 1'b1;
      executed_exception.cause = EXC_INST_ADDR_MISALIGNED;
      executed_exception.tval = branch_redirect.target_pc;
    end else if (!executed_exception.valid && (id_ex_bus_i.ctrl.mem_cmd != MEM_NONE) && data_misaligned) begin
      executed_exception.valid = 1'b1;
      executed_exception.cause = (id_ex_bus_i.ctrl.mem_cmd == MEM_STORE) ?
          EXC_STORE_ADDR_MISALIGNED : EXC_LOAD_ADDR_MISALIGNED;
      executed_exception.tval = alu_result;
    end else if (!executed_exception.valid && (id_ex_bus_i.ctrl.csr_cmd != CSR_NONE) &&
                 !csr_read_rsp_i.valid) begin
      executed_exception.valid = 1'b1;
      executed_exception.cause = EXC_ILLEGAL_INSTR;
      executed_exception.tval = id_ex_bus_i.instruction.instr;
    end

    redirect_o = branch_redirect;
    // taken 控制流若恰好落到顺序 PC+4，不需要产生多余的前端 flush。
    // 这也统一了退休 debug 的 redirect 语义：只报告下一 PC 的实际改道。
    if (executed_exception.valid ||
        (branch_redirect.valid && (branch_redirect.target_pc == pc_plus_4)))
      redirect_o.valid = 1'b0;
  end

  assign pc_plus_4 = id_ex_bus_i.instruction.pc + word_t'(4);

  always_comb begin
    wb_req = '0;
    wb_req.valid = id_ex_bus_i.ctrl.rd_write;
    wb_req.rd_addr = id_ex_bus_i.reg_addr.rd_addr;

    case (id_ex_bus_i.ctrl.wb_sel)
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
        wb_req.wdata = csr_read_rsp_i.data;
      end
      default: wb_req = '0;
    endcase

    // x0 写入在这里提前消除，减少后续前递和写回端的无效比较活动。
    if ((wb_req.rd_addr == ZeroReg) || executed_exception.valid) wb_req.valid = 1'b0;
  end

  always_comb begin
    mem_req = '0;
    mem_req.valid = (id_ex_bus_i.ctrl.mem_cmd != MEM_NONE) && !executed_exception.valid;
    mem_req.write = (id_ex_bus_i.ctrl.mem_cmd == MEM_STORE);
    mem_req.size = id_ex_bus_i.ctrl.mem_size;
    mem_req.sign_ext = id_ex_bus_i.ctrl.mem_sign_ext;
    mem_req.addr = alu_result;
    // 保留未经 lane 对齐的 rs2 数据，移位和 byte enable 生成放在 MEM。
    mem_req.wdata = rs2_value;
  end

  always_comb begin
    unique case (id_ex_bus_i.ctrl.csr_cmd)
      CSR_RW: csr_new_value = csr_source;
      CSR_RS: csr_new_value = csr_read_rsp_i.data | csr_source;
      CSR_RC: csr_new_value = csr_read_rsp_i.data & ~csr_source;
      default: csr_new_value = '0;
    endcase

    // CSR 指令把旧值放入普通 GPR 写回路径，把新值作为提交请求随指令送到 WB。
    // RS/RC 的零源操作数按规范只读，不形成 CSR 写请求。
    commit_ctrl = '0;
    commit_ctrl.serialize = id_ex_bus_i.ctrl.serialize || executed_exception.valid;
    commit_ctrl.system_op = id_ex_bus_i.ctrl.system_op;
    commit_ctrl.csr_write.valid = (id_ex_bus_i.ctrl.csr_cmd != CSR_NONE) &&
        ((id_ex_bus_i.ctrl.csr_cmd == CSR_RW) || (csr_source != '0)) && !executed_exception.valid;
    commit_ctrl.csr_write.addr = id_ex_bus_i.ctrl.csr_addr;
    commit_ctrl.csr_write.wdata = csr_new_value;
  end

  // 前递数据未就绪时不允许当前 ID/EX 事务进入 EX/MEM 寄存器。
  // ID 已知的异常与 SYSTEM/CSR 一样，必须先等待所有更老事务排空。
  // 这也避免取指错误携带的无意义指令位影响串行化判断。
  assign serialize_stall = (id_ex_bus_i.ctrl.serialize || id_ex_bus_i.exception.valid) &&
      !serialize_ready_i;
  assign ex_mem_input_valid = id_ex_valid_i && !forward_stall && !serialize_stall && !flush_i;
  assign id_ex_ready_o = ex_mem_input_ready && !forward_stall && !serialize_stall && !flush_i;
  assign ex_execute_fire = ex_mem_input_valid && ex_mem_input_ready;

  always_comb begin
    executed_ex_mem_bus = '0;
    executed_ex_mem_bus.mem_req = mem_req;
    executed_ex_mem_bus.wb_req = wb_req;
    executed_ex_mem_bus.exception = executed_exception;
    executed_ex_mem_bus.commit = commit_ctrl;
    executed_ex_mem_bus.retire.instruction = id_ex_bus_i.instruction;
    executed_ex_mem_bus.retire.mem_op = !mem_req.valid ? RETIRE_MEM_NONE :
        (mem_req.write ? RETIRE_MEM_WRITE : RETIRE_MEM_READ);
    executed_ex_mem_bus.retire.mem_size = mem_req.size;
    executed_ex_mem_bus.retire.mem_addr = mem_req.addr;
    executed_ex_mem_bus.retire.mem_data = mem_req.wdata;
    executed_ex_mem_bus.retire.redirect_valid = redirect_o.valid;
    executed_ex_mem_bus.retire.redirect_target_pc = redirect_o.target_pc;
  end

  // EX/MEM 与 ID/EX 一样使用单入口双向握手寄存器。满载且 MEM ready 时
  // 可以同拍 pop/push，不会在连续指令之间插入气泡。
  stream_register #(
    .T(ex_mem_bus_t)
  ) u_ex_mem_register (
    .clk_i,
    .rst_ni,
    .flush_i,
    .valid_i(ex_mem_input_valid),
    .ready_o(ex_mem_input_ready),
    .data_i(executed_ex_mem_bus),
    .valid_o(ex_mem_valid_o),
    .ready_i(ex_mem_ready_i),
    .data_o(ex_mem_bus_o)
  );

  // verilog_format: off
  `ASSERT_STABLE(
    ExMemStable,
    ex_mem_valid_o,
    ex_mem_ready_i,
    ex_mem_bus_o,
    ex_mem_bus_t'(0),
    clk_i,
    !rst_ni || flush_i,
    "EX/MEM payload must remain stable while valid is waiting for ready."
  )

  `ASSERT(
    ExMemValidStable,
    ex_mem_valid_o && !ex_mem_ready_i |=> ex_mem_valid_o,
    clk_i,
    !rst_ni || flush_i,
    "EX/MEM valid must remain asserted until ready."
  )
  // verilog_format: on
endmodule
