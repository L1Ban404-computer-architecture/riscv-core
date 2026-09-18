// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "common/assertions.svh"

// 写回与架构提交级。
//
// 提交 GPR/CSR 写入、trap、MRET 和 FENCE.I，并产生改道与提交事件。
// 本模块是唯一架构提交点且无下游背压；CSR 状态与寄存器堆在核心顶层；
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
  csr_commit_if.producer csr_commit,
  csr_status_if.consumer csr_status,
  commit_event_if.producer commit_event,
  redirect_if.producer redirect,
  output logic icache_invalidate_o,
  writeback_if.producer wb
);

  ////////////////////////
  // 私有类型与内部信号 //
  ////////////////////////

  logic wb_fire;
  commit_kind_e commit_kind;
  logic trap_commit;
  logic mret_commit;
  logic fence_i_commit;
  csr_write_payload_t csr_write;
  mem_wb_payload_t mem_wb_payload;
  writeback_payload_t wb_req;

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
    csr_commit.payload.trap_is_interrupt = mem_wb_payload.exception.is_interrupt;
    csr_commit.payload.trap_cause = mem_wb_payload.exception.cause;
    csr_commit.payload.trap_tval = mem_wb_payload.exception.tval;
    csr_commit.payload.mret = mret_commit;
  end

  //////////////////////////
  // 架构提交与控制流改道 //
  //////////////////////////

  // WB 没有下游背压，是唯一架构提交点。所有寄存器、CSR、trap 状态变化都由
  // wb_fire 门控，避免无效 MEM/WB payload 产生副作用。
  assign mem_wb.ready = 1'b1;
  assign wb_fire = mem_wb.valid && mem_wb.ready;
  assign commit_kind = commit_kind_from_context(mem_wb_payload);
  assign commit_event.valid = wb_fire;
  assign commit_event.kind = commit_kind;

  always_comb begin
    // 架构提交优先级固定为：trap entry > MRET > FENCE.I > 普通 CSR/GPR 写回。
    trap_commit = wb_fire && (commit_kind == COMMIT_TRAP);
    mret_commit = wb_fire && (commit_kind == COMMIT_MRET);
    fence_i_commit = wb_fire && (commit_kind == COMMIT_FENCE_I);

    csr_write = mem_wb_payload.commit.csr_write;
    csr_write.valid = wb_fire && !trap_commit && !mret_commit &&
        mem_wb_payload.commit.csr_write.valid;

    // trap、MRET 和 FENCE.I 都从 WB 发起全流水 flush；FENCE.I 重新取其顺序
    // 后继，避免在失效前已经取到的年轻指令继续执行。
    redirect.valid = 1'b0;
    redirect.payload.target_pc = '0;
    icache_invalidate_o = fence_i_commit;
    if (trap_commit) begin
      redirect.valid = 1'b1;
      redirect.payload.target_pc = csr_status.mtvec;
    end else if (mret_commit) begin
      // 读取提交前的 mepc；csr_unit 已将 mepc[1:0] 实现为只读零。
      redirect.valid = 1'b1;
      redirect.payload.target_pc = csr_status.mepc;
    end else if (fence_i_commit) begin
      redirect.valid = 1'b1;
      redirect.payload.target_pc = mem_wb_payload.meta.pc + word_t'(4);
    end

    wb_req = '0;
    if (wb_fire && !trap_commit && !mret_commit) wb_req = mem_wb_payload.wb_req;
  end

`ifdef SYNTHESIS
  // 综合去掉 assertion 后不再消费时钟复位；保留端口以便仿真期协议检查。
  logic unused_clk_rst;
  assign unused_clk_rst = ^{clk_i, rst_ni};
`endif

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
    fence_i_commit |-> (redirect.valid &&
                        (redirect.payload.target_pc == (mem_wb_payload.meta.pc + word_t'(4)))),
    clk_i,
    !rst_ni,
    "Committed FENCE.I must flush younger work and refetch from PC+4."
  )
  // verilog_format: on

endmodule
