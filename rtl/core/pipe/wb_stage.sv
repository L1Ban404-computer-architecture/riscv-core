// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module wb_stage (
  input logic clk_i,
  input logic rst_ni,

  input logic mem_wb_valid_i,
  output logic mem_wb_ready_o,
  input mem_wb_bus_t mem_wb_bus_i,

  // CSR 状态归 WB 所有，但串行化 CSR 指令在 EX 组合读取旧值。
  input csr_addr_t csr_read_addr_i,
  output csr_read_rsp_bus_t csr_read_rsp_o,

  output pipeline_control_bus_t control_o,

  output wb_req_bus_t wb_req_o,
  output core_debug_bus_t core_debug_o
);

  logic wb_fire;
  logic trap_commit;
  logic mret_commit;
  exception_bus_t effective_exception;
  csr_write_bus_t csr_write;
  csr_state_bus_t csr_state;
  csr_state_bus_t csr_current_state;

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
        (csr_current_state.mepc[1:0] != 2'b00)) begin
      effective_exception.valid = 1'b1;
      effective_exception.cause = EXC_INST_ADDR_MISALIGNED;
      effective_exception.tval = csr_current_state.mepc;
    end

    // 架构提交优先级固定为：trap entry > MRET > 普通 CSR/GPR 写回。
    trap_commit = wb_fire && effective_exception.valid;
    mret_commit = wb_fire && !trap_commit &&
        (mem_wb_bus_i.commit.system_op == SYS_MRET);

    csr_write = mem_wb_bus_i.commit.csr_write;
    csr_write.valid = wb_fire && !trap_commit && !mret_commit &&
        mem_wb_bus_i.commit.csr_write.valid;

    // trap 和 MRET 都从 WB 发起全流水 kill；功能目标分别读取提交前 mtvec/mepc。
    control_o = '0;
    if (trap_commit) begin
      control_o.redirect.valid = 1'b1;
      control_o.redirect.target_pc = csr_current_state.mtvec;
      control_o.redirect.reason = REDIR_TRAP;
    end else if (mret_commit) begin
      control_o.redirect.valid = 1'b1;
      control_o.redirect.target_pc = csr_current_state.mepc;
      control_o.redirect.reason = REDIR_MRET;
    end
    control_o.kill = control_o.redirect.valid;

    wb_req_o = '0;
    if (wb_fire && !trap_commit && !mret_commit) wb_req_o = mem_wb_bus_i.wb_req;
  end

  // Trace 是提交结果的纯观察者，与 CSR 下一状态计算分块，避免观察通路被综合器
  // 误认为会反向影响 trap/CSR 控制。
  always_comb begin
    core_debug_o = '0;
    core_debug_o.csr = csr_state;

    if (wb_fire) begin
      core_debug_o.valid = 1'b1;
      core_debug_o.pc = mem_wb_bus_i.debug.pc;
      core_debug_o.instr = mem_wb_bus_i.debug.instr;
      core_debug_o.gpr_we = wb_req_o.valid && wb_req_o.data_valid;
      core_debug_o.gpr_waddr = wb_req_o.rd_addr;
      core_debug_o.gpr_wdata = wb_req_o.wdata;
      core_debug_o.mem_valid = mem_wb_bus_i.debug.mem_valid && !trap_commit && !mret_commit;
      core_debug_o.mem_write = mem_wb_bus_i.debug.mem_write;
      core_debug_o.mem_size = mem_wb_bus_i.debug.mem_size;
      core_debug_o.mem_addr = mem_wb_bus_i.debug.mem_addr;
      core_debug_o.mem_wdata = mem_wb_bus_i.debug.mem_wdata;
      core_debug_o.redirect_valid = mem_wb_bus_i.debug.redirect_valid;
      core_debug_o.redirect_target_pc = mem_wb_bus_i.debug.redirect_target_pc;
      // 异常指令本身仍退休一条 trace，但不报告正常 GPR/访存提交。
      core_debug_o.trap = trap_commit;
      core_debug_o.intr = effective_exception.is_interrupt;
      core_debug_o.cause = {{(XLen-4) {1'b0}}, effective_exception.cause};
      core_debug_o.tval = effective_exception.tval;

      if (control_o.redirect.valid) begin
        core_debug_o.redirect_valid = 1'b1;
        core_debug_o.redirect_target_pc = control_o.redirect.target_pc;
      end
    end
  end

  // CSR 寄存器物理上归属 WB。读端口只观察 current state；写、trap 和 MRET
  // 都由 wb_fire 派生的提交信号驱动，因此不会提前改变架构状态。
  csr_unit u_csr_unit (
    .clk_i,
    .rst_ni,
    .read_addr_i(csr_read_addr_i),
    .read_rsp_o(csr_read_rsp_o),
    .write_i(csr_write),
    .trap_i(trap_commit),
    .trap_epc_i(mem_wb_bus_i.debug.pc),
    .trap_exception_i(effective_exception),
    .mret_i(mret_commit),
    .state_o(csr_state),
    .current_state_o(csr_current_state)
  );

endmodule
