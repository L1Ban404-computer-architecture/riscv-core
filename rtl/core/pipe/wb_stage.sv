// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module wb_stage (
  input logic mem_wb_valid_i,
  output logic mem_wb_ready_o,
  input mem_wb_bus_t mem_wb_bus_i,

  input word_t csr_mstatus_i,
  input word_t csr_mtvec_i,
  input word_t csr_mepc_i,
  input word_t csr_mcause_i,
  input word_t csr_mtval_i,
  input word_t csr_current_mtvec_i,
  input word_t csr_current_mepc_i,

  output csr_write_bus_t csr_write_o,
  output logic trap_commit_o,
  output pc_t trap_epc_o,
  output exception_bus_t trap_exception_o,
  output logic mret_commit_o,
  output redirect_bus_t commit_redirect_o,
  output logic pipeline_kill_o,

  output wb_req_bus_t wb_req_o,
  output core_debug_bus_t core_debug_o
);

  logic wb_fire;
  exception_bus_t effective_exception;

  // WB 没有下游背压，是唯一架构提交点。所有寄存器、CSR、trap 状态变化都由
  // wb_fire 门控，避免无效 MEM/WB payload 产生副作用。
  assign mem_wb_ready_o = 1'b1;
  assign wb_fire = mem_wb_valid_i && mem_wb_ready_o;

  always_comb begin
    // MRET 的目标来自提交前 mepc。IALIGN=32 下目标未对齐时，不执行 MRET，
    // 而是把 MRET 指令自身转换为 instruction-address-misaligned trap。
    effective_exception = mem_wb_bus_i.exception;
    if (!effective_exception.valid &&
        (mem_wb_bus_i.commit.system_op == SYS_MRET) &&
        (csr_current_mepc_i[1:0] != 2'b00)) begin
      effective_exception.valid = 1'b1;
      effective_exception.cause = EXC_INST_ADDR_MISALIGNED;
      effective_exception.tval = csr_current_mepc_i;
    end

    // 架构提交优先级固定为：trap entry > MRET > 普通 CSR/GPR 写回。
    trap_commit_o = wb_fire && effective_exception.valid;
    trap_epc_o = mem_wb_bus_i.debug.pc;
    trap_exception_o = effective_exception;
    mret_commit_o = wb_fire && !trap_commit_o &&
        (mem_wb_bus_i.commit.system_op == SYS_MRET);

    csr_write_o = mem_wb_bus_i.commit.csr_write;
    csr_write_o.valid = wb_fire && !trap_commit_o && !mret_commit_o &&
        mem_wb_bus_i.commit.csr_write.valid;

    // trap 和 MRET 都从 WB 发起全流水 kill；功能目标分别读取提交前 mtvec/mepc。
    commit_redirect_o = '0;
    if (trap_commit_o) begin
      commit_redirect_o.valid = 1'b1;
      commit_redirect_o.target_pc = csr_current_mtvec_i;
      commit_redirect_o.reason = REDIR_TRAP;
    end else if (mret_commit_o) begin
      commit_redirect_o.valid = 1'b1;
      commit_redirect_o.target_pc = csr_current_mepc_i;
      commit_redirect_o.reason = REDIR_MRET;
    end
    pipeline_kill_o = commit_redirect_o.valid;

    wb_req_o = '0;
    core_debug_o = '0;
    core_debug_o.mstatus = csr_mstatus_i;
    core_debug_o.mtvec = csr_mtvec_i;
    core_debug_o.mepc = csr_mepc_i;
    core_debug_o.mcause = csr_mcause_i;
    core_debug_o.mtval = csr_mtval_i;

    if (wb_fire) begin
      if (!trap_commit_o && !mret_commit_o) wb_req_o = mem_wb_bus_i.wb_req;

      core_debug_o.valid = 1'b1;
      core_debug_o.pc = mem_wb_bus_i.debug.pc;
      core_debug_o.instr = mem_wb_bus_i.debug.instr;
      core_debug_o.gpr_we = wb_req_o.valid && wb_req_o.data_valid;
      core_debug_o.gpr_waddr = wb_req_o.rd_addr;
      core_debug_o.gpr_wdata = wb_req_o.wdata;
      core_debug_o.mem_valid = mem_wb_bus_i.debug.mem_valid && !trap_commit_o && !mret_commit_o;
      core_debug_o.mem_write = mem_wb_bus_i.debug.mem_write;
      core_debug_o.mem_size = mem_wb_bus_i.debug.mem_size;
      core_debug_o.mem_addr = mem_wb_bus_i.debug.mem_addr;
      core_debug_o.mem_wdata = mem_wb_bus_i.debug.mem_wdata;
      core_debug_o.redirect_valid = mem_wb_bus_i.debug.redirect_valid;
      core_debug_o.redirect_target_pc = mem_wb_bus_i.debug.redirect_target_pc;
      // 异常指令本身仍退休一条 trace，但不报告正常 GPR/访存提交。
      core_debug_o.trap = trap_commit_o;
      core_debug_o.intr = effective_exception.is_interrupt;
      core_debug_o.cause = {{(XLen-4) {1'b0}}, effective_exception.cause};
      core_debug_o.tval = effective_exception.tval;

      if (commit_redirect_o.valid) begin
        core_debug_o.redirect_valid = 1'b1;
        core_debug_o.redirect_target_pc = commit_redirect_o.target_pc;
      end
    end
  end

endmodule
