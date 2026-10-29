// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 唯一架构提交点，无下游背压。提交优先级：trap > MRET > FENCE.I > 普通写回。
module wb_stage
  import riscv_core_pkg::*;
(
  // 提交事务
  mem_wb_if.consumer mem_wb,
  csr_read_if.requester csr_read,
  csr_commit_if.producer csr_commit,
  csr_status_if.consumer csr_status,
  redirect_if.producer redirect,
  gpr_write_if.producer wb
`ifndef SYNTHESIS
  , output riscv_debug_pkg::writeback_debug_payload_t debug_o
`endif
);

  commit_kind_e commit_kind;
  logic is_csr;
  word_t csr_source, csr_new_value, writeback_value;

  // WB 恒 ready；提交分类只解释 payload，所有副作用由 fire 门控。
  assign mem_wb.ready = 1'b1;
  assign commit_kind = classify_commit(mem_wb.payload.exception.valid, mem_wb.payload.commit);
  assign is_csr = mem_wb.payload.commit.csr.cmd != CSR_NONE;
  assign csr_read.index = mem_wb.payload.commit.csr.index;
  // 同一流水 value 在 CSR 指令中是源操作数，普通写回中是已完成的 GPR 结果。
  assign csr_source = mem_wb.payload.value;
  assign writeback_value = is_csr ? csr_read.data : mem_wb.payload.value;

  // CSR 旧值在提交点读取，新值不再占用流水寄存器或接入 EX 前递。
  always_comb begin
    case (mem_wb.payload.commit.csr.cmd)
      CSR_RS: csr_new_value = csr_read.data | csr_source;
      CSR_RC: csr_new_value = csr_read.data & ~csr_source;
      default: csr_new_value = csr_source;
    endcase
  end

  always_comb begin
    redirect.valid = 1'b0;
    redirect.payload = '0;
    wb.valid = 1'b0;
    wb.payload = '0;
    csr_commit.payload = '{
      op: CSR_COMMIT_NONE,
      index: mem_wb.payload.commit.csr.index,
      wdata: csr_new_value,
      trap_epc: mem_wb.payload.pc,
      trap_cause: mem_wb.payload.exception.cause,
      trap_tval: mem_wb.payload.exception.tval
    };

    // 按 trap、MRET、FENCE.I、普通写回的优先级生成互斥提交副作用。
    if (mem_wb.fire) begin
      if (commit_kind == COMMIT_TRAP) begin
        csr_commit.payload.op = CSR_COMMIT_TRAP;
        redirect.valid = 1'b1;
        redirect.payload.target_pc = csr_status.mtvec;
      end else if (commit_kind == COMMIT_MRET) begin
        csr_commit.payload.op = CSR_COMMIT_MRET;
        redirect.valid = 1'b1;
        // csr_unit 保证 mepc[1:0] 为零，读取的是提交前的状态。
        redirect.payload.target_pc = csr_status.mepc;
      end else if (commit_kind == COMMIT_FENCE_I) begin
        // 更老访存已完成；WB 改道与流水屏障取消年轻访存。
        redirect.valid = 1'b1;
        redirect.payload = '{target_pc: mem_wb.payload.pc + pc_t'(4), imem_invalidate: 1'b1};
      end else begin
        wb.valid = mem_wb.payload.gpr.write && (mem_wb.payload.gpr.ready || is_csr);
        wb.payload = '{rd_addr: mem_wb.payload.gpr.addr,
                       wdata: writeback_value};
        if (is_csr && mem_wb.payload.commit.csr.write)
          csr_commit.payload.op = CSR_COMMIT_WRITE;
      end
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
