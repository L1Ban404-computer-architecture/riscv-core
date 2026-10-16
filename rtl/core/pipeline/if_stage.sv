// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单笔在途取指：保存请求 PC，将回应送入 IF/ID。存储侧回应至少晚一拍。
module if_stage
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
  import riscv_core_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  input pc_t boot_pc_i,
  redirect_if.consumer redirect,
  output logic imem_flush_o,
  core_bus_if.master imem,
  if_id_if.producer result
`ifndef SYNTHESIS
  , output riscv_debug_pkg::fetch_debug_payload_t debug_o
`endif
);

  pc_t pc_q;
  pc_t pending_pc;
  logic meta_ready, meta_valid;

  // redirect 同拍仍可能接受旧 PC；下一拍 flush 才能覆盖这笔请求。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q <= boot_pc_i;
      imem_flush_o <= 1'b0;
    end else begin
      imem_flush_o <= redirect.valid;
      if (redirect.valid) pc_q <= redirect.target_pc;
      else if (imem.req_fire) pc_q <= pc_q + pc_t'(4);
    end
  end

  assign imem.req_valid = rst_ni;
  assign imem.req_payload = '{
      addr: pc_q, write: 1'b0, size: CORE_BUS_SIZE_WORD, wdata: '0
  };
  // 元数据当拍清空；存储侧下一拍取消旧请求，并保留同拍进入的目标 PC 请求。
  fall_through_register #(
    .T(pc_t)
  ) u_fetch_meta (
    .clk_i,
    .rst_ni,
    .flush_i(redirect.valid),
    .valid_i(imem.req_fire),
    .ready_o(meta_ready),
    .data_i(pc_q),
    .valid_o(meta_valid),
    .ready_i(imem.rsp_fire),
    .data_o(pending_pc)
  );

  // 回应携带原请求 PC；访问错误也沿 IF/ID 传递。
  assign imem.rsp_ready = redirect.valid || result.ready;
  assign result.valid = imem.rsp_valid && !redirect.valid;

  always_comb begin
    result.payload = '0;
    result.payload.meta.pc = pending_pc;
    result.payload.meta.instr = instr_t'(imem.rsp_payload.rdata);
    if (imem.rsp_payload.error) begin
      result.payload.exception = raise_exception('0, EXC_INST_ACCESS_FAULT, pending_pc);
    end
  end

`ifndef SYNTHESIS
  assign debug_o = '{
    request_fire: imem.req_fire,
    response_fire: imem.rsp_fire,
    request_pc: pc_q,
    result_valid: result.valid,
    instr: result.payload.meta.instr,
    access_fault: imem.rsp_payload.error,
    imem_flush: imem_flush_o,
    bus: '{req_valid: imem.req_valid, req_ready: imem.req_ready,
           rsp_valid: imem.rsp_valid, rsp_ready: imem.rsp_ready}
  };

  NoSecondImemRequestWhileOutstanding: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !imem.req_fire || meta_ready));
  ImemResponseHasPendingRequest: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !imem.rsp_valid || meta_valid));
`endif

endmodule
