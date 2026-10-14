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
  if_id_if.producer if_id
);

  typedef struct packed {
    pc_t pc;
`ifndef SYNTHESIS
    logic [63:0] instid;
`endif
  } fetch_meta_t;

  pc_t pc_q;
  fetch_meta_t request_meta, pending_meta;
  logic meta_ready, meta_valid;
  if_id_payload_t response_data;
  logic response_ready, if_id_valid;
`ifndef SYNTHESIS
  logic [63:0] instid_q;
`endif

  // redirect 同拍仍可能接受旧 PC；下一拍 flush 才能覆盖这笔请求。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q <= boot_pc_i;
      imem_flush_o <= 1'b0;
`ifndef SYNTHESIS
      instid_q <= 64'd1;
`endif
    end else begin
      imem_flush_o <= redirect.valid;
      if (redirect.valid) pc_q <= redirect.payload.target_pc;
      else if (imem.req_fire) pc_q <= pc_q + pc_t'(4);
`ifndef SYNTHESIS
      if (imem.req_fire) instid_q <= instid_q + 64'd1;
`endif
    end
  end

  assign imem.req_valid = rst_ni;
  assign imem.req_payload = '{
      addr: pc_q, write: 1'b0, size: CORE_BUS_SIZE_WORD, wdata: '0
  };
  assign request_meta.pc = pc_q;
`ifndef SYNTHESIS
  assign request_meta.instid = instid_q;
`endif

  // 元数据当拍清空；存储侧下一拍取消旧请求，并保留同拍进入的目标 PC 请求。
  fall_through_register #(
    .T(fetch_meta_t)
  ) u_fetch_meta (
    .clk_i,
    .rst_ni,
    .flush_i(redirect.valid),
    .valid_i(imem.req_fire),
    .ready_o(meta_ready),
    .data_i(request_meta),
    .valid_o(meta_valid),
    .ready_i(imem.rsp_fire),
    .data_o(pending_meta)
  );

  // 回应携带原请求的 PC 和编号；访问错误也沿 IF/ID 传递。
  assign imem.rsp_ready = redirect.valid || response_ready;
  assign if_id.valid = if_id_valid && !redirect.valid;

  always_comb begin
    response_data = '0;
    response_data.meta.pc = pending_meta.pc;
    response_data.meta.instr = instr_t'(imem.rsp_payload.rdata);
`ifndef SYNTHESIS
    response_data.meta.instid = pending_meta.instid;
`endif
    if (imem.rsp_payload.error) begin
      response_data.exception = raise_exception('0, EXC_INST_ACCESS_FAULT, pending_meta.pc);
    end
  end

  fall_through_register #(
    .T(if_id_payload_t)
  ) u_if_id (
    .clk_i,
    .rst_ni,
    .flush_i(redirect.valid),
    .valid_i(imem.rsp_valid && !redirect.valid),
    .ready_o(response_ready),
    .data_i(response_data),
    .valid_o(if_id_valid),
    .ready_i(if_id.ready && !redirect.valid),
    .data_o(if_id.payload)
  );

`ifndef SYNTHESIS
  NoSecondImemRequestWhileOutstanding: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !imem.req_fire || meta_ready));
  ImemResponseHasPendingRequest: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !imem.rsp_valid || meta_valid));
`endif

endmodule
