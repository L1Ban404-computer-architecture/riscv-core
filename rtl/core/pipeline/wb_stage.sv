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

  // WB 恒 ready；提交分类只解释 payload，所有副作用由 fire 门控。
  assign mem_wb.ready = 1'b1;
  assign commit_kind = commit_kind_from_context(mem_wb.payload);

  always_comb begin
    redirect.valid = 1'b0;
    redirect.payload = '0;
    wb.valid = 1'b0;
    wb.payload = '0;
    csr_commit.payload = '{
      op: CSR_COMMIT_NONE,
      addr: mem_wb.payload.commit.csr_write.addr,
      wdata: mem_wb.payload.commit.csr_write.wdata,
      trap_epc: mem_wb.payload.pc,
      trap_cause: mem_wb.payload.exception.cause,
      trap_tval: mem_wb.payload.exception.tval
    };

    // 同一个提交分支同时决定 GPR、CSR 和改道，优先级由 commit_kind 统一给出。
    if (mem_wb.fire) begin
      case (commit_kind)
        COMMIT_TRAP: begin
          csr_commit.payload.op = CSR_COMMIT_TRAP;
          redirect.valid = 1'b1;
          redirect.payload.target_pc = csr_status.mtvec;
        end
        COMMIT_MRET: begin
          csr_commit.payload.op = CSR_COMMIT_MRET;
          redirect.valid = 1'b1;
          // csr_unit 保证 mepc[1:0] 为零，读取的是提交前的状态。
          redirect.payload.target_pc = csr_status.mepc;
        end
        default: begin
          wb.valid = mem_wb.payload.wb_req.valid && mem_wb.payload.wb_req.data_valid;
          wb.payload = '{rd_addr: mem_wb.payload.wb_req.rd_addr,
                         wdata: mem_wb.payload.wb_req.wdata};
          if (mem_wb.payload.commit.csr_write.valid)
            csr_commit.payload.op = CSR_COMMIT_WRITE;
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  assign debug_o = '{
    valid: mem_wb.valid, ready: mem_wb.ready, kind: commit_kind,
    gpr_we: wb.valid, gpr_waddr: wb.payload.rd_addr, gpr_wdata: wb.payload.wdata,
    redirect: '{valid: redirect.valid, target_pc: redirect.payload.target_pc}
  };
`endif

endmodule
