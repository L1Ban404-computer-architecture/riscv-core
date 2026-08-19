// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "common/assertions.svh"

// 写回与架构提交级。
//
// 提交 GPR/CSR 写入、trap、MRET 和 FENCE.I，产生全局冲刷与改道，并生成最终退休快照。
// 本模块是唯一架构提交点且无下游背压；debug_retire 与提交事件同周期组合产生；
// 同周期状态更新严格遵循 trap > MRET > FENCE.I > 普通 CSR/GPR 写回的优先级。
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
  output logic icache_invalidate_o,
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
  logic fence_i_commit;
  exception_payload_t effective_exception;
  csr_write_payload_t csr_write;
  mem_wb_payload_t mem_wb_payload;
  writeback_payload_t wb_req;
  retire_debug_payload_t debug_payload;
  csr_commit_if csr_commit ();
  csr_state_if csr_state ();
  word_t current_mtvec;
  word_t current_mepc;

  ////////////////////////////
  // 提交事务解包与输出打包 //
  ////////////////////////////

  assign mem_wb_payload = mem_wb.payload;

  assign wb.payload = wb_req;

  always_comb begin
    csr_commit.payload = '0;
    csr_commit.payload.write = csr_write;
    csr_commit.payload.trap = trap_commit;
    csr_commit.payload.trap_epc = mem_wb_payload.meta.pc;
    csr_commit.payload.trap_is_interrupt = effective_exception.is_interrupt;
    csr_commit.payload.trap_cause = effective_exception.cause;
    csr_commit.payload.trap_tval = effective_exception.tval;
    csr_commit.payload.mret = mret_commit;
  end

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

    // 架构提交优先级固定为：trap entry > MRET > FENCE.I > 普通 CSR/GPR 写回。
    trap_commit = wb_fire && effective_exception.valid;
    mret_commit = wb_fire && !trap_commit && (mem_wb_payload.commit.system_op == SYS_MRET);
    fence_i_commit = wb_fire && !trap_commit && !mret_commit && mem_wb_payload.commit.fence_i;

    csr_write = mem_wb_payload.commit.csr_write;
    csr_write.valid = wb_fire && !trap_commit && !mret_commit &&
        mem_wb_payload.commit.csr_write.valid;

    // trap、MRET 和 FENCE.I 都从 WB 发起全流水 flush；FENCE.I 重新取其顺序
    // 后继，避免在失效前已经取到的年轻指令继续执行。
    redirect.valid = 1'b0;
    redirect.payload.target_pc = '0;
    flush_o = 1'b0;
    icache_invalidate_o = fence_i_commit;
    if (trap_commit) begin
      redirect.valid = 1'b1;
      redirect.payload.target_pc = current_mtvec;
    end else if (mret_commit) begin
      redirect.valid = 1'b1;
      redirect.payload.target_pc = current_mepc;
    end else if (fence_i_commit) begin
      redirect.valid = 1'b1;
      redirect.payload.target_pc = mem_wb_payload.meta.pc + word_t'(4);
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

  // valid 为零时其余字段无效，因此完整 debug payload 只在 WB 最终生成。
  always_comb begin
    debug_payload = '0;
    debug_payload.meta = mem_wb_payload.meta;
    debug_payload.gpr_we = wb_req.valid && wb_req.data_valid;
    debug_payload.gpr_waddr = wb_req.rd_addr;
    debug_payload.gpr_wdata = wb_req.wdata;
    debug_payload.mem = mem_wb_payload.retire_mem;
    debug_payload.redirect = mem_wb_payload.redirect;
    debug_payload.csr = csr_state.payload;
    if (trap_commit || mret_commit) debug_payload.mem.mem_op = RETIRE_MEM_NONE;
    // FENCE.I 的 PC+4 重取指是前端维护动作，不是架构控制流改道，故不泄露到
    // retire debug 的 redirect 语义。
    debug_payload.redirect.valid = (!fence_i_commit && redirect.valid) ||
        mem_wb_payload.redirect.valid;
    debug_payload.redirect.target_pc = (!fence_i_commit && redirect.valid) ? redirect.payload.target_pc :
        mem_wb_payload.redirect.target_pc;
  end

  assign debug_retire.valid = wb_fire;
  assign debug_retire.payload = debug_payload;

  // FENCE.I 的失效请求必须精确对应一次实际提交，并同时发起顺序后继重取指和
  // 后端冲刷；被异常或 flush 丢弃的事务不得产生该外部副作用。
  // verilog_format: off
  `ASSERT(
    FenceIInvalidateExact,
    icache_invalidate_o == fence_i_commit,
    clk_i,
    !rst_ni,
    "I-cache invalidation must occur exactly once when FENCE.I commits."
  )

  `ASSERT(
    FenceIRefetchAndFlush,
    fence_i_commit |-> (flush_o && redirect.valid &&
                        (redirect.payload.target_pc == (mem_wb_payload.meta.pc + word_t'(4)))),
    clk_i,
    !rst_ni,
    "Committed FENCE.I must flush younger work and refetch from PC+4."
  )
  // verilog_format: on

endmodule
