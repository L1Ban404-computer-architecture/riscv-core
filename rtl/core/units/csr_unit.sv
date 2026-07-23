// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module csr_unit (
  input logic clk_i,
  input logic rst_ni,

  input csr_addr_t read_addr_i,
  output csr_read_rsp_bus_t read_rsp_o,

  input csr_write_bus_t write_i,
  input logic trap_i,
  input pc_t trap_epc_i,
  input logic trap_is_interrupt_i,
  input exception_cause_e trap_cause_i,
  input word_t trap_tval_i,
  input logic mret_i,

  output csr_state_bus_t state_o,
  output word_t current_mtvec_o,
  output word_t current_mepc_o
);

  // 当前核心只运行于 M-mode。mstatus 仅实现异常进入/返回所需的
  // MIE、MPIE 和 MPP 字段；MPP 固定为唯一支持的 M-mode，其他位读零。
  localparam word_t MstatusMie  = word_t'(1 << 3);
  localparam word_t MstatusMpie = word_t'(1 << 7);
  localparam word_t MstatusMpp  = word_t'(3 << 11);

  csr_state_bus_t state_q, state_d;

  always_comb begin
    read_rsp_o.valid = 1'b1;
    unique case (read_addr_i)
      CsrMstatus: read_rsp_o.data = state_q.mstatus;
      CsrMtvec:   read_rsp_o.data = state_q.mtvec;
      CsrMepc:    read_rsp_o.data = state_q.mepc;
      CsrMcause:  read_rsp_o.data = state_q.mcause;
      CsrMtval:   read_rsp_o.data = state_q.mtval;
      default: begin
        read_rsp_o.valid = 1'b0;
        read_rsp_o.data = '0;
      end
    endcase
  end

  always_comb begin
    state_d = state_q;

    // 同一退休周期只允许一种 CSR 状态变更。优先级与 WB 架构提交顺序一致：
    // trap entry > MRET > 普通 CSR 写。
    if (trap_i) begin
      // IALIGN=32：无论来源是软件写入还是 trap entry，mepc[1:0] 恒为零。
      state_d.mepc = trap_epc_i & word_t'(~3);
      state_d.mcause = {trap_is_interrupt_i, {(XLen-5) {1'b0}}, trap_cause_i};
      state_d.mtval = trap_tval_i;
      if ((state_q.mstatus & MstatusMie) != '0)
        state_d.mstatus = state_q.mstatus | MstatusMpie;
      else state_d.mstatus = state_q.mstatus & ~MstatusMpie;
      state_d.mstatus = (state_d.mstatus & ~MstatusMie) | MstatusMpp;
    end else if (mret_i) begin
      if ((state_q.mstatus & MstatusMpie) != '0)
        state_d.mstatus = state_q.mstatus | MstatusMie;
      else state_d.mstatus = state_q.mstatus & ~MstatusMie;
      state_d.mstatus = state_d.mstatus | MstatusMpie | MstatusMpp;
    end else if (write_i.valid) begin
      unique case (write_i.addr)
        CsrMstatus: begin
          state_d.mstatus = (write_i.wdata & (MstatusMie | MstatusMpie)) | MstatusMpp;
        end
        CsrMtvec:   state_d.mtvec = write_i.wdata & word_t'(~3);
        // 本核只支持 IALIGN=32，mepc[1:0] 按规范恒为零。
        CsrMepc:    state_d.mepc = write_i.wdata & word_t'(~3);
        CsrMcause:  state_d.mcause = write_i.wdata;
        CsrMtval:   state_d.mtval = write_i.wdata;
        default: ;
      endcase
    end
  end

  // 退休快照输出下一状态，使仿真环境在 WB fire 当周期观察到本条指令提交后的
  // CSR 值；控制通路另用窄化的 current_mtvec/current_mepc 读取提交前目标。
  assign state_o = state_d;
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
