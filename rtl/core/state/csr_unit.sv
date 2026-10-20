// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// M-mode CSR：组合读、WB 提交写入及 trap/MRET 状态转换。
// IALIGN=32，mepc 低两位恒零。
module csr_unit
  import riscv_core_pkg::*;
(
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // CSR 事务
  csr_read_if.responder csr_read,
  csr_commit_if.consumer commit,
  csr_status_if.producer status
`ifndef SYNTHESIS
  , output riscv_core_pkg::csr_state_payload_t debug_o
`endif
);

  // 私有类型与 CSR 状态

  // 当前核心只运行于 M-mode。mstatus 仅实现异常进入/返回所需的
  // MIE、MPIE 和 MPP 字段；MPP 固定为唯一支持的 M-mode，其他位读零。
  localparam word_t MstatusMie = word_t'(1 << 3);
  localparam word_t MstatusMpie = word_t'(1 << 7);
  localparam word_t MstatusMpp = word_t'(3 << 11);

  csr_state_payload_t state_q, state_d;

  // CSR 组合读取

  always_comb begin
    unique case (csr_read.index)
      // ysyx 厂商标识和本核学号标识由硬件常量提供，不占用可写状态。
      CSR_IDX_MVENDORID: csr_read.data = 32'h7973_7978;
      CSR_IDX_MARCHID: csr_read.data = 32'd25080230;
      CSR_IDX_MSTATUS: csr_read.data = state_q.mstatus;
      CSR_IDX_MTVEC: csr_read.data = state_q.mtvec;
      CSR_IDX_MEPC: csr_read.data = state_q.mepc;
      CSR_IDX_MCAUSE: csr_read.data = state_q.mcause;
      CSR_IDX_MTVAL: csr_read.data = state_q.mtval;
      default: csr_read.data = '0;
    endcase
  end

  // CSR 提交与异常状态转换

  always_comb begin
    state_d = state_q;

    unique case (commit.payload.op)
      CSR_COMMIT_TRAP: begin
        // IALIGN=32：无论来源是软件写入还是 trap entry，mepc[1:0] 恒为零。
        state_d.mepc = commit.payload.trap_epc & word_t'(~3);
        // 当前只接收同步异常，mcause 的 interrupt 位恒为零。
        state_d.mcause = {{(XLen - 4) {1'b0}}, commit.payload.trap_cause};
        state_d.mtval = commit.payload.trap_tval;
        if ((state_q.mstatus & MstatusMie) != '0) state_d.mstatus = state_q.mstatus | MstatusMpie;
        else state_d.mstatus = state_q.mstatus & ~MstatusMpie;
        state_d.mstatus = (state_d.mstatus & ~MstatusMie) | MstatusMpp;
      end
      CSR_COMMIT_MRET: begin
        if ((state_q.mstatus & MstatusMpie) != '0) state_d.mstatus = state_q.mstatus | MstatusMie;
        else state_d.mstatus = state_q.mstatus & ~MstatusMie;
        state_d.mstatus = state_d.mstatus | MstatusMpie | MstatusMpp;
      end
      CSR_COMMIT_WRITE: begin
        unique case (commit.payload.index)
          CSR_IDX_MSTATUS: begin
            state_d.mstatus = (commit.payload.wdata & (MstatusMie | MstatusMpie)) | MstatusMpp;
          end
          CSR_IDX_MTVEC: state_d.mtvec = commit.payload.wdata & word_t'(~3);
          // 本核只支持 IALIGN=32，mepc[1:0] 按规范恒为零。
          CSR_IDX_MEPC: state_d.mepc = commit.payload.wdata & word_t'(~3);
          CSR_IDX_MCAUSE: state_d.mcause = commit.payload.wdata;
          CSR_IDX_MTVAL: state_d.mtval = commit.payload.wdata;
          default: ;
        endcase
      end
      default: ;
    endcase
  end

  // 状态输出与寄存

  assign status.mtvec = state_q.mtvec;
  assign status.mepc = state_q.mepc;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= '{mstatus: MstatusMpp, mtvec: '0, mepc: '0, mcause: '0, mtval: '0};
    end else begin
      state_q <= state_d;
    end
  end

`ifndef SYNTHESIS
  assign debug_o = state_d;
`endif

endmodule
