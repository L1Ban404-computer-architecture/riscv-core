// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 唯一架构提交点，无下游背压。提交优先级：trap > MRET > FENCE.I > 普通写回。
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
  redirect_if.producer redirect,
  output logic icache_invalidate_o,
  gpr_write_if.producer wb
`ifndef SYNTHESIS
  , output riscv_debug_pkg::writeback_debug_payload_t debug_o
`endif
);

  commit_kind_e commit_kind;
  logic trap_commit;
  logic mret_commit;
  logic fence_i_commit;

  // 架构提交与控制流改道

  // WB 没有下游背压，是唯一架构提交点。所有寄存器、CSR、trap 状态变化都由
  // mem_wb.fire 门控，避免无效 MEM/WB payload 产生副作用。
  assign mem_wb.ready = 1'b1;
  assign commit_kind = commit_kind_from_context(mem_wb.payload);

  always_comb begin
    // 架构提交优先级固定为：trap entry > MRET > FENCE.I > 普通 CSR/GPR 写回。
    trap_commit = mem_wb.fire && (commit_kind == COMMIT_TRAP);
    mret_commit = mem_wb.fire && (commit_kind == COMMIT_MRET);
    fence_i_commit = mem_wb.fire && (commit_kind == COMMIT_FENCE_I);

    // trap、MRET 和 FENCE.I 都从 WB 发起全流水 flush；FENCE.I 重新取其顺序
    // 后继，避免在失效前已经取到的年轻指令继续执行。
    redirect.valid = 1'b0;
    redirect.target_pc = '0;
    icache_invalidate_o = fence_i_commit;
    if (trap_commit) begin
      redirect.valid = 1'b1;
      redirect.target_pc = csr_status.mtvec;
    end else if (mret_commit) begin
      // 读取提交前的 mepc；csr_unit 已将 mepc[1:0] 实现为只读零。
      redirect.valid = 1'b1;
      redirect.target_pc = csr_status.mepc;
    end else if (fence_i_commit) begin
      redirect.valid = 1'b1;
      redirect.target_pc = mem_wb.payload.pc + word_t'(4);
    end

    wb.valid = 1'b0;
    wb.rd_addr = '0;
    wb.wdata = '0;
    if (mem_wb.fire && !trap_commit && !mret_commit) begin
      wb.valid = mem_wb.payload.wb_req.valid && mem_wb.payload.wb_req.data_valid;
      wb.rd_addr = mem_wb.payload.wb_req.rd_addr;
      wb.wdata = mem_wb.payload.wb_req.wdata;
    end
  end

  always_comb begin
    csr_commit.payload = '0;
    if (trap_commit) csr_commit.payload.op = CSR_COMMIT_TRAP;
    else if (mret_commit) csr_commit.payload.op = CSR_COMMIT_MRET;
    else if (mem_wb.fire && mem_wb.payload.commit.csr_write.valid)
      csr_commit.payload.op = CSR_COMMIT_WRITE;
    csr_commit.payload.addr = mem_wb.payload.commit.csr_write.addr;
    csr_commit.payload.wdata = mem_wb.payload.commit.csr_write.wdata;
    csr_commit.payload.trap_epc = mem_wb.payload.pc;
    csr_commit.payload.trap_cause = mem_wb.payload.exception.cause;
    csr_commit.payload.trap_tval = mem_wb.payload.exception.tval;
  end

`ifdef SYNTHESIS
  // 综合去掉 assertion 后不再消费时钟复位；保留端口以便仿真期协议检查。
  logic unused_clk_rst;
  assign unused_clk_rst = ^{clk_i, rst_ni};
`endif

  // FENCE.I 的失效请求必须精确对应一次实际提交，并同时重取 PC+4。
  // 被异常或 flush 丢弃的事务不得产生该外部副作用。
`ifndef SYNTHESIS
  assign debug_o = '{
    valid: mem_wb.valid, ready: mem_wb.ready, kind: commit_kind,
    gpr_we: wb.valid, gpr_waddr: wb.rd_addr, gpr_wdata: wb.wdata,
    redirect: '{valid: redirect.valid, target_pc: redirect.target_pc}
  };

  FenceIInvalidateExact: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      icache_invalidate_o == fence_i_commit));
  FenceIRefetchAndFlush: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !fence_i_commit || (redirect.valid &&
      (redirect.target_pc == (mem_wb.payload.pc + word_t'(4))))));
`endif

endmodule
