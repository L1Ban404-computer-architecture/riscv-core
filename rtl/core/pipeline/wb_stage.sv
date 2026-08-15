// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 写回与架构提交级。
//
// 提交 GPR/CSR 写入、trap 和 MRET，产生全局冲刷与改道，并生成最终退休快照。
// 本模块是唯一架构提交点且无下游背压；debug_retire 与提交事件同周期组合产生；
// 同周期状态更新严格遵循 trap > MRET > 普通 CSR/GPR 写回的优先级。
module wb_stage
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 提交事务
  mem_wb_if.consumer mem_wb,
  csr_read_if.responder csr_read,
  redirect_if.producer redirect,
  output logic flush_o,
  writeback_if.producer wb,

  // 退休观测
  retire_debug_if.producer debug_retire
);

  ////////////////////////
  // 私有类型与内部信号 //
  ////////////////////////

  logic wb_fire;
  logic trap_commit;
  logic mret_commit;
  exception_payload_t effective_exception;
  csr_write_payload_t csr_write;
  mem_wb_payload_t mem_wb_payload;
  writeback_payload_t wb_req;
  csr_commit_if csr_commit();
  csr_state_if csr_state();
  word_t current_mtvec;
  word_t current_mepc;

  ////////////////////////////
  // 提交事务解包与输出打包 //
  ////////////////////////////

  assign mem_wb_payload = mem_wb.payload;

  assign wb.valid = wb_req.valid;
  assign wb.data_valid = wb_req.data_valid;
  assign wb.rd_addr = wb_req.rd_addr;
  assign wb.wdata = wb_req.wdata;

  assign csr_commit.write_valid = csr_write.valid;
  assign csr_commit.write_addr = csr_write.addr;
  assign csr_commit.write_data = csr_write.wdata;
  assign csr_commit.trap = trap_commit;
  assign csr_commit.trap_epc = mem_wb_payload.pc;
  assign csr_commit.trap_is_interrupt = effective_exception.is_interrupt;
  assign csr_commit.trap_cause = effective_exception.cause;
  assign csr_commit.trap_tval = effective_exception.tval;
  assign csr_commit.mret = mret_commit;

  //////////////////////////////////
  // 架构提交、改道与退休快照生成 //
  //////////////////////////////////

  // WB 没有下游背压，是唯一架构提交点。所有寄存器、CSR、trap 状态变化都由
  // wb_fire 门控，避免无效 MEM/WB payload 产生副作用。
  assign mem_wb.ready = 1'b1;
  assign wb_fire = mem_wb.valid && mem_wb.ready;

  always_comb begin
    // MRET 的目标来自提交前 mepc。csr_unit 按 IALIGN=32 将 mepc[1:0]
    // 实现为只读零，因此隐式读取的返回地址始终满足指令对齐要求。
    effective_exception = mem_wb_payload.exception;

    // 架构提交优先级固定为：trap entry > MRET > 普通 CSR/GPR 写回。
    trap_commit = wb_fire && effective_exception.valid;
    mret_commit = wb_fire && !trap_commit &&
        (mem_wb_payload.commit.system_op == SYS_MRET);

    csr_write = mem_wb_payload.commit.csr_write;
    csr_write.valid = wb_fire && !trap_commit && !mret_commit &&
        mem_wb_payload.commit.csr_write.valid;

    // trap 和 MRET 都从 WB 发起全流水 flush；功能目标分别读取提交前 mtvec/mepc。
    redirect.valid = 1'b0;
    redirect.target_pc = '0;
    flush_o = 1'b0;
    if (trap_commit) begin
      redirect.valid = 1'b1;
      redirect.target_pc = current_mtvec;
    end else if (mret_commit) begin
      redirect.valid = 1'b1;
      redirect.target_pc = current_mepc;
    end
    flush_o = redirect.valid;

    wb_req = '0;
    if (wb_fire && !trap_commit && !mret_commit) wb_req = mem_wb_payload.wb_req;

  end

  //////////////////
  // CSR 架构状态 //
  //////////////////

  // CSR 寄存器物理上归属 WB。读端口只观察 current state；写、trap 和 MRET
  // 都由 wb_fire 派生的提交信号驱动，因此不会提前改变架构状态。
  csr_unit u_csr_unit (
    .clk_i,
    .rst_ni,
    .csr_read,
    .commit(csr_commit),
    .state(csr_state),
    .current_mtvec_o(current_mtvec),
    .current_mepc_o(current_mepc)
  );

  ////////////////////////
  // 退休调试输出       //
  ////////////////////////

  // valid 为零时其余字段无效，因此不再为 debug_retire 提供默认清零值。
  assign debug_retire.valid = wb_fire;
  assign debug_retire.pc = mem_wb_payload.debug.pc;
  assign debug_retire.instr = mem_wb_payload.debug.instr;
  assign debug_retire.instid = mem_wb_payload.debug.instid;
  assign debug_retire.gpr_we = wb_req.valid && wb_req.data_valid;
  assign debug_retire.gpr_waddr = wb_req.rd_addr;
  assign debug_retire.gpr_wdata = wb_req.wdata;
  assign debug_retire.mem_op = (trap_commit || mret_commit) ?
      RETIRE_MEM_NONE : mem_wb_payload.debug.mem_op;
  assign debug_retire.mem_size = mem_wb_payload.debug.mem_size;
  assign debug_retire.mem_addr = mem_wb_payload.debug.mem_addr;
  assign debug_retire.mem_data = mem_wb_payload.debug.mem_data;
  assign debug_retire.redirect_valid =
      redirect.valid || mem_wb_payload.debug.redirect_valid;
  assign debug_retire.redirect_target_pc = redirect.valid ?
      redirect.target_pc : mem_wb_payload.debug.redirect_target_pc;
  assign debug_retire.csr_mstatus = csr_state.payload.mstatus;
  assign debug_retire.csr_mtvec = csr_state.payload.mtvec;
  assign debug_retire.csr_mepc = csr_state.payload.mepc;
  assign debug_retire.csr_mcause = csr_state.payload.mcause;
  assign debug_retire.csr_mtval = csr_state.payload.mtval;

endmodule
