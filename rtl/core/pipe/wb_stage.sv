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
  output logic core_retire_valid_o,
  output core_retire_debug_bus_t core_retire_debug_o,
  output core_state_debug_bus_t core_state_debug_o
);

  logic wb_fire;
  logic trap_commit;
  logic mret_commit;
  exception_bus_t effective_exception;
  csr_write_bus_t csr_write;
  csr_state_bus_t csr_state;
  csr_state_bus_t csr_current_state;
  logic [63:0] debug_cycle_count_q;

  // WB 没有下游背压，是唯一架构提交点。所有寄存器、CSR、trap 状态变化都由
  // wb_fire 门控，避免无效 MEM/WB payload 产生副作用。
  assign mem_wb_ready_o = 1'b1;
  assign wb_fire = mem_wb_valid_i && mem_wb_ready_o;

  always_comb begin
    // MRET 的目标来自提交前 mepc。csr_unit 按 IALIGN=32 将 mepc[1:0]
    // 实现为只读零，因此隐式读取的返回地址始终满足指令对齐要求。
    effective_exception = mem_wb_bus_i.exception;

    // 架构提交优先级固定为：trap entry > MRET > 普通 CSR/GPR 写回。
    trap_commit = wb_fire && effective_exception.valid;
    mret_commit = wb_fire && !trap_commit &&
        (mem_wb_bus_i.commit.system_op == SYS_MRET);

    csr_write = mem_wb_bus_i.commit.csr_write;
    csr_write.valid = wb_fire && !trap_commit && !mret_commit &&
        mem_wb_bus_i.commit.csr_write.valid;

    // trap 和 MRET 都从 WB 发起全流水 flush；功能目标分别读取提交前 mtvec/mepc。
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
    control_o.flush_backend = control_o.redirect.valid;

    wb_req_o = '0;
    if (wb_fire && !trap_commit && !mret_commit) wb_req_o = mem_wb_bus_i.wb_req;
  end

  // valid 每周期指示是否发生退休；两个结构体只在退休沿更新并保持最后一次
  // 退休快照。周期计数器独立运行，退休时采样包含当前提交沿的周期号。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      debug_cycle_count_q <= '0;
      core_retire_valid_o <= 1'b0;
      core_retire_debug_o <= '0;
      core_state_debug_o <= '0;
    end else begin
      debug_cycle_count_q <= debug_cycle_count_q + 64'd1;
      core_retire_valid_o <= wb_fire;

      if (wb_fire) begin
        core_retire_debug_o <= '{
          pc: mem_wb_bus_i.retire.instruction.pc,
          instr: mem_wb_bus_i.retire.instruction.instr,
          gpr_we: wb_req_o.valid && wb_req_o.data_valid,
          gpr_waddr: wb_req_o.rd_addr,
          gpr_wdata: wb_req_o.wdata,
          mem_op: (trap_commit || mret_commit) ?
              RETIRE_MEM_NONE : mem_wb_bus_i.retire.mem_op,
          mem_size: mem_wb_bus_i.retire.mem_size,
          mem_addr: mem_wb_bus_i.retire.mem_addr,
          mem_data: mem_wb_bus_i.retire.mem_data,
          redirect_valid: control_o.redirect.valid ||
              mem_wb_bus_i.retire.redirect_valid,
          redirect_target_pc: control_o.redirect.valid ?
              control_o.redirect.target_pc :
              mem_wb_bus_i.retire.redirect_target_pc,
          csr: csr_state
        };

        core_state_debug_o <= '{
          cycle_count: debug_cycle_count_q + 64'd1,
          instret_count: core_state_debug_o.instret_count + 64'd1,
          trap: trap_commit,
          intr: trap_commit && effective_exception.is_interrupt,
          cause: trap_commit ?
              {{(XLen-4) {1'b0}}, effective_exception.cause} : '0,
          tval: trap_commit ? effective_exception.tval : '0
        };
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
    .trap_epc_i(mem_wb_bus_i.retire.instruction.pc),
    .trap_exception_i(effective_exception),
    .mret_i(mret_commit),
    .state_o(csr_state),
    .current_state_o(csr_current_state)
  );

endmodule
