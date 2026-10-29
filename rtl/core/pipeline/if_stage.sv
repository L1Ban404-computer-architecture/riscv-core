// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单笔在途取指：保存请求 PC，将回应送入 IF/ID。存储侧回应至少晚一拍。
module if_stage
  import riscv_bus_pkg::*;
  import riscv_core_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  input pc_t boot_pc_i,
  redirect_if.consumer ex_redirect,
  redirect_if.consumer wb_redirect,
  branch_update_if.consumer branch_update,
  output logic imem_flush_o,
  output logic imem_invalidate_o,
  core_bus_if.master imem,
  if_id_if.producer result
`ifndef SYNTHESIS
  , output riscv_debug_pkg::fetch_debug_payload_t debug_o
`endif
);

  pc_t pc_q;
  typedef struct packed {
    pc_t pc;
    branch_prediction_payload_t prediction;
  } fetch_meta_t;
  fetch_meta_t pending;
  branch_predict_if prediction ();
  logic meta_ready, meta_valid;
  redirect_if resolved_redirect ();

  assign prediction.tag = btb_tag_t'(pc_q >> 2);
  branch_predictor u_branch_predictor (
    .clk_i, .rst_ni,
    .invalidate_i(imem_invalidate_o),
    .predict(prediction),
    .update(branch_update)
  );

  // WB 比 EX 更老，精确异常要求 WB 改道优先；目标和失效标志一起选择。
  assign resolved_redirect.valid = wb_redirect.valid || ex_redirect.valid;
  assign resolved_redirect.payload = wb_redirect.valid ? wb_redirect.payload : ex_redirect.payload;

  // FENCE.I 在 EX 执行当拍请求取指状态失效；无效改道的 payload 不产生副作用。
  // 该事件不经过下方 imem_flush_o 的一拍延迟。
  assign imem_invalidate_o = resolved_redirect.valid && resolved_redirect.payload.imem_invalidate;

  assign imem.req_valid = rst_ni;
  assign imem.req_payload = '{
      addr: pc_q, write: 1'b0, size: CORE_BUS_SIZE_WORD, wdata: '0
  };
  // 回应至少晚一拍，无需组合直通。改道当拍接受的旧请求不保存元数据；
  // 存储侧下一拍取消旧请求，同时接受目标 PC 请求及其新元数据。
  stream_register #(
    .T(fetch_meta_t)
  ) u_fetch_meta (
    .clk_i,
    .rst_ni,
    .flush_i(resolved_redirect.valid),
    .valid_i(imem.req_fire && !resolved_redirect.valid),
    .ready_o(meta_ready),
    .data_i('{pc: pc_q, prediction: prediction.payload}),
    .valid_o(meta_valid),
    .ready_i(imem.rsp_fire),
    .data_o(pending)
  );

  // 回应携带原请求 PC；访问错误也沿 IF/ID 传递。
  assign imem.rsp_ready = resolved_redirect.valid || result.ready;
  assign result.valid = imem.rsp_valid && !resolved_redirect.valid;

  always_comb begin
    result.payload = '0;
    result.payload.meta.pc = pending.pc;
    result.payload.meta.prediction = pending.prediction;
    result.payload.meta.instr = instr_t'(imem.rsp_payload.rdata);
    if (imem.rsp_payload.error) begin
      result.payload.exception = raise_exception('0, EXC_INST_ACCESS_FAULT, pending.pc);
    end
  end

  // redirect 同拍仍可能接受旧 PC；下一拍 flush 才能覆盖这笔请求。
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      pc_q <= boot_pc_i;
      imem_flush_o <= 1'b0;
    end else begin
      imem_flush_o <= resolved_redirect.valid;
      if (resolved_redirect.valid) pc_q <= resolved_redirect.payload.target_pc;
      else if (imem.req_fire)
        pc_q <= prediction.payload.taken ? btb_target_pc(pc_q, prediction.payload.target) :
            pc_q + pc_t'(4);
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
      !imem.rsp_valid || resolved_redirect.valid || meta_valid));
`endif

endmodule
