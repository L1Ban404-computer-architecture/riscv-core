// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module csr_unit (
  input logic clk_i,
  input logic rst_ni,

  input csr_addr_t read_addr_i,
  output logic read_valid_o,
  output word_t read_data_o,

  input csr_write_bus_t write_i,
  input logic trap_i,
  input pc_t trap_epc_i,
  input exception_bus_t trap_exception_i,
  input logic mret_i,

  output word_t mstatus_o,
  output word_t mtvec_o,
  output word_t mepc_o,
  output word_t mcause_o,
  output word_t mtval_o,
  output word_t current_mtvec_o,
  output word_t current_mepc_o
);

  // 当前核心只运行于 M-mode。mstatus 仅实现异常进入/返回所需的
  // MIE、MPIE 和 MPP 字段；其余位暂按普通可读写状态保存。
  localparam word_t MstatusMie  = word_t'(1 << 3);
  localparam word_t MstatusMpie = word_t'(1 << 7);
  localparam word_t MstatusMpp  = word_t'(3 << 11);

  word_t mstatus_q, mstatus_d;
  word_t mtvec_q, mtvec_d;
  word_t mepc_q, mepc_d;
  word_t mcause_q, mcause_d;
  word_t mtval_q, mtval_d;

  always_comb begin
    read_valid_o = 1'b1;
    unique case (read_addr_i)
      CsrMstatus: read_data_o = mstatus_q;
      CsrMtvec:   read_data_o = mtvec_q;
      CsrMepc:    read_data_o = mepc_q;
      CsrMcause:  read_data_o = mcause_q;
      CsrMtval:   read_data_o = mtval_q;
      default: begin
        read_valid_o = 1'b0;
        read_data_o = '0;
      end
    endcase
  end

  always_comb begin
    mstatus_d = mstatus_q;
    mtvec_d = mtvec_q;
    mepc_d = mepc_q;
    mcause_d = mcause_q;
    mtval_d = mtval_q;

    // 同一退休周期只允许一种 CSR 状态变更。优先级与 WB 架构提交顺序一致：
    // trap entry > MRET > 普通 CSR 写。
    if (trap_i) begin
      mepc_d = trap_epc_i;
      mcause_d = {trap_exception_i.is_interrupt, {(XLen-5) {1'b0}}, trap_exception_i.cause};
      mtval_d = trap_exception_i.tval;
      if ((mstatus_q & MstatusMie) != '0) mstatus_d = mstatus_q | MstatusMpie;
      else mstatus_d = mstatus_q & ~MstatusMpie;
      mstatus_d = (mstatus_d & ~MstatusMie) | MstatusMpp;
    end else if (mret_i) begin
      if ((mstatus_q & MstatusMpie) != '0) mstatus_d = mstatus_q | MstatusMie;
      else mstatus_d = mstatus_q & ~MstatusMie;
      mstatus_d = mstatus_d | MstatusMpie | MstatusMpp;
    end else if (write_i.valid) begin
      unique case (write_i.addr)
        CsrMstatus: mstatus_d = (write_i.wdata & ~MstatusMpp) | MstatusMpp;
        CsrMtvec:   mtvec_d = write_i.wdata & word_t'(~3);
        CsrMepc:    mepc_d = write_i.wdata;
        CsrMcause:  mcause_d = write_i.wdata;
        CsrMtval:   mtval_d = write_i.wdata;
        default: ;
      endcase
    end
  end

  // 退休快照输出下一状态，使仿真环境在 WB fire 当周期观察到本条指令提交后的
  // CSR 值；控制通路另用 current_* 读取寄存器当前值，避免形成组合反馈环。
  assign mstatus_o = mstatus_d;
  assign mtvec_o = mtvec_d;
  assign mepc_o = mepc_d;
  assign mcause_o = mcause_d;
  assign mtval_o = mtval_d;
  assign current_mtvec_o = mtvec_q;
  assign current_mepc_o = mepc_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus_q <= MstatusMpp;
      mtvec_q <= '0;
      mepc_q <= '0;
      mcause_q <= '0;
      mtval_q <= '0;
    end else begin
      mstatus_q <= mstatus_d;
      mtvec_q <= mtvec_d;
      mepc_q <= mepc_d;
      mcause_q <= mcause_d;
      mtval_q <= mtval_d;
    end
  end

endmodule
