// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// M-mode CSR 状态单元。
//
// 实现机器级 CSR 的组合读取、普通写入、trap 进入和 MRET 恢复，并输出
// 当前控制目标与提交后状态快照。
// 仅实现列出的 M-mode CSR；同周期更新优先级固定为 trap > MRET > 普通写；
// IALIGN=32，因此 mepc[1:0] 始终为零。
module csr_unit
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // CSR 事务
  csr_read_if.responder csr_read,
  csr_commit_if.consumer commit,
  csr_state_if.producer state,

  // 当前控制目标
  output word_t current_mtvec_o,
  output word_t current_mepc_o
);

  /////////////////////////
  // 私有类型与 CSR 状态 //
  /////////////////////////

  // 当前核心只运行于 M-mode。mstatus 仅实现异常进入/返回所需的
  // MIE、MPIE 和 MPP 字段；MPP 固定为唯一支持的 M-mode，其他位读零。
  localparam word_t MstatusMie  = word_t'(1 << 3);
  localparam word_t MstatusMpie = word_t'(1 << 7);
  localparam word_t MstatusMpp  = word_t'(3 << 11);

  csr_state_payload_t state_q, state_d;

  //////////////////
  // CSR 组合读取 //
  //////////////////

  always_comb begin
    csr_read.valid = 1'b1;
    unique case (csr_read.addr)
      // ysyx 厂商标识和本核学号标识由硬件常量提供，不占用可写状态。
      CsrMvendorid: csr_read.data = 32'h7973_7978;
      CsrMarchid:   csr_read.data = 32'd25080230;
      CsrMstatus: csr_read.data = state_q.mstatus;
      CsrMtvec:   csr_read.data = state_q.mtvec;
      CsrMepc:    csr_read.data = state_q.mepc;
      CsrMcause:  csr_read.data = state_q.mcause;
      CsrMtval:   csr_read.data = state_q.mtval;
      default: begin
        csr_read.valid = 1'b0;
        csr_read.data = '0;
      end
    endcase
  end

  ////////////////////////////
  // CSR 提交与异常状态转换 //
  ////////////////////////////

  always_comb begin
    state_d = state_q;

    // 同一退休周期只允许一种 CSR 状态变更。优先级与 WB 架构提交顺序一致：
    // trap entry > MRET > 普通 CSR 写。
    if (commit.trap) begin
      // IALIGN=32：无论来源是软件写入还是 trap entry，mepc[1:0] 恒为零。
      state_d.mepc = commit.trap_epc & word_t'(~3);
      state_d.mcause = {commit.trap_is_interrupt,
                        {(XLen-5) {1'b0}}, commit.trap_cause};
      state_d.mtval = commit.trap_tval;
      if ((state_q.mstatus & MstatusMie) != '0)
        state_d.mstatus = state_q.mstatus | MstatusMpie;
      else state_d.mstatus = state_q.mstatus & ~MstatusMpie;
      state_d.mstatus = (state_d.mstatus & ~MstatusMie) | MstatusMpp;
    end else if (commit.mret) begin
      if ((state_q.mstatus & MstatusMpie) != '0)
        state_d.mstatus = state_q.mstatus | MstatusMie;
      else state_d.mstatus = state_q.mstatus & ~MstatusMie;
      state_d.mstatus = state_d.mstatus | MstatusMpie | MstatusMpp;
    end else if (commit.write_valid) begin
      unique case (commit.write_addr)
        CsrMstatus: begin
          state_d.mstatus = (commit.write_data & (MstatusMie | MstatusMpie)) | MstatusMpp;
        end
        CsrMtvec:   state_d.mtvec = commit.write_data & word_t'(~3);
        // 本核只支持 IALIGN=32，mepc[1:0] 按规范恒为零。
        CsrMepc:    state_d.mepc = commit.write_data & word_t'(~3);
        CsrMcause:  state_d.mcause = commit.write_data;
        CsrMtval:   state_d.mtval = commit.write_data;
        default: ;
      endcase
    end
  end

  ////////////////////
  // 状态输出与寄存 //
  ////////////////////

  // 退休快照输出下一状态，使仿真环境在 WB fire 当周期观察到本条指令提交后的
  // CSR 值；控制通路另用窄化的 current_mtvec/current_mepc 读取提交前目标。
  assign state.payload = state_d;
  assign current_mtvec_o = state_q.mtvec;
  assign current_mepc_o = state_q.mepc;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= '{mstatus: MstatusMpp,
                   mtvec: '0,
                   mepc: '0,
                   mcause: '0,
                   mtval: '0};
    end else begin
      state_q <= state_d;
    end
  end

endmodule
