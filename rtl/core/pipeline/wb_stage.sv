// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 唯一架构提交点，无下游背压。提交优先级：trap > MRET > 普通写回。
module wb_stage
  import riscv_core_pkg::*;
(
  // 提交事务
  mem_wb_if.consumer mem_wb,
  csr_commit_if.producer csr_commit,
  csr_status_if.consumer csr_status,
  redirect_if.producer redirect,
  gpr_write_if.producer wb
`ifndef SYNTHESIS
  , output riscv_debug_pkg::writeback_debug_payload_t debug_o
`endif
);

  commit_kind_e commit_kind;
  logic trap_commit;
  logic mret_commit;

  // 架构提交与控制流改道

  // WB 没有下游背压，是唯一架构提交点。所有寄存器、CSR、trap 状态变化都由
  // mem_wb.fire 门控，避免无效 MEM/WB payload 产生副作用。
  assign mem_wb.ready = 1'b1;
  assign commit_kind = commit_kind_from_context(mem_wb.payload);

  always_comb begin
    // 架构提交优先级固定为：trap entry > MRET > 普通 CSR/GPR 写回。
    trap_commit = mem_wb.fire && (commit_kind == COMMIT_TRAP);
    mret_commit = mem_wb.fire && (commit_kind == COMMIT_MRET);
    // trap 和 MRET 从 WB 发起全流水 flush。
    redirect.valid = 1'b0;
    redirect.payload = '0;
    if (trap_commit) begin
      redirect.valid = 1'b1;
      redirect.payload.target_pc = csr_status.mtvec;
    end else if (mret_commit) begin
      // 读取提交前的 mepc；csr_unit 已将 mepc[1:0] 实现为只读零。
      redirect.valid = 1'b1;
      redirect.payload.target_pc = csr_status.mepc;
    end

    wb.valid = 1'b0;
    wb.payload.rd_addr = '0;
    wb.payload.wdata = '0;
    if (mem_wb.fire && !trap_commit && !mret_commit) begin
      wb.valid = mem_wb.payload.wb_req.valid && mem_wb.payload.wb_req.data_valid;
      wb.payload.rd_addr = mem_wb.payload.wb_req.rd_addr;
      wb.payload.wdata = mem_wb.payload.wb_req.wdata;
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

`ifndef SYNTHESIS
  assign debug_o = '{
    valid: mem_wb.valid, ready: mem_wb.ready, kind: commit_kind,
    gpr_we: wb.valid, gpr_waddr: wb.payload.rd_addr, gpr_wdata: wb.payload.wdata,
    redirect: '{valid: redirect.valid, target_pc: redirect.payload.target_pc}
  };
`endif

endmodule
