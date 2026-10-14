// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 指令取指级：请求元数据和返回指令各用一个 fall-through 寄存器缓存。
// I-cache 保证单笔在途、响应至少晚一拍，并允许响应与下一笔请求同拍握手。
module if_stage
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
  import riscv_core_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  input pc_t boot_pc_i,
  redirect_if.consumer redirect,
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
  logic pending_stale_q;
  fetch_meta_t request_meta, pending_meta;
  logic meta_ready, meta_valid;
  if_id_payload_t response_data;
  logic response_ready, if_id_valid;
  logic drop_response;
`ifndef SYNTHESIS
  logic [63:0] instid_q;
`endif

  // PC 与在途请求状态。redirect 优先更新 PC；同拍接受的旧 PC 请求也需丢弃。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q <= boot_pc_i;
      pending_stale_q <= 1'b0;
    end else begin
      if (redirect.valid) pc_q <= redirect.payload.target_pc;
      else if (imem.req_fire) pc_q <= pc_q + pc_t'(4);

      // 请求更新优先，避免同拍旧响应清除新请求的 stale 状态。
      if (imem.req_fire) pending_stale_q <= redirect.valid;
      else if (imem.rsp_fire) pending_stale_q <= 1'b0;
      else if (redirect.valid && meta_valid) pending_stale_q <= 1'b1;
    end
  end

  // 请求由 I-cache 的 ready 控制接受；未握手的 PC 可由 redirect 改写。
  assign imem.req_valid = rst_ni;
  assign imem.req_payload = '{
      addr: pc_q, write: 1'b0, size: CORE_BUS_SIZE_WORD, wdata: '0
  };
  assign request_meta.pc = pc_q;
`ifndef SYNTHESIS
  assign request_meta.instid = instid_q;
`endif

  // redirect 不清空元数据，旧响应仍需配对并排空。
  fall_through_register #(
    .T(fetch_meta_t)
  ) u_fetch_meta (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .valid_i(imem.req_fire),
    .ready_o(meta_ready),
    .data_i(request_meta),
    .valid_o(meta_valid),
    .ready_i(imem.rsp_fire),
    .data_o(pending_meta)
  );

  // 响应与元数据合并；旧路径响应直接丢弃，不受 ID 反压影响。
  assign drop_response = redirect.valid || pending_stale_q;
  assign imem.rsp_ready = drop_response || response_ready;

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

  assign if_id.valid = if_id_valid && !redirect.valid;

  fall_through_register #(
    .T(if_id_payload_t)
  ) u_if_id (
    .clk_i,
    .rst_ni,
    .flush_i(redirect.valid),
    .valid_i(imem.rsp_valid && !drop_response),
    .ready_o(response_ready),
    .data_i(response_data),
    .valid_o(if_id_valid),
    .ready_i(if_id.ready && !redirect.valid),
    .data_o(if_id.payload)
  );

`ifndef SYNTHESIS
  // 仿真指令编号按请求握手分配。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) instid_q <= 64'd1;
    else if (imem.req_fire) instid_q <= instid_q + 64'd1;
  end

  NoSecondImemRequestWhileOutstanding: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !imem.req_fire || meta_ready));
  ImemResponseHasPendingRequest: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !imem.rsp_valid || meta_valid));
  BootPcAligned: assert property (@(posedge clk_i) (
      rst_ni || (boot_pc_i[1:0] == 2'b00)));
`endif

endmodule
