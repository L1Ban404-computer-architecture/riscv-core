// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "common/assertions.svh"

// 指令取指级。
//
// 当前 I-cache 最多接受一笔未完成请求，因此 IF 使用单笔 pending 元数据寄存器，
// 而非可支持多 outstanding 的 PC FIFO。命中请求和响应仍可同拍握手：响应写入
// 非 fall-through 指令 FIFO 后，于下一周期对 ID 有效。该寄存器边界切断
// ID/I-cache ready 到请求 valid 的组合回路。
//
// 已向 CoreBus 声明 valid 的请求不可撤销。redirect 会立即清空已返回指令、
// 更新 PC，并将已发出或已展示的旧路径请求标记为 stale；旧响应返回后握手并丢弃。
module if_stage
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
  import riscv_core_pkg::*;
#(
  // 保留参数接口兼容性；当前阻塞式 I-cache 要求该值固定为 1。
  parameter int unsigned FetchOutstandingDepth = 1,
  // 已返回指令队列深度。
  parameter int unsigned IfIdQueueDepth = 2
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input pc_t boot_pc_i,
  redirect_if.consumer redirect,

  // 取指与流水事务
  core_bus_if.master imem,
  if_id_if.producer if_id
);

  ////////////////////////
  // 私有类型与内部状态 //
  ////////////////////////

  typedef struct packed {pc_t pc;} fetch_req_t;

  typedef struct packed {
    pc_t pc;
    logic [63:0] instid;
  } fetch_meta_t;

  // pc_q 是下一次分配给 u_req_hold 的取指 PC。boot_pc_i 在复位释放后的第一个
  // 周期被采样；后续 PC 只由顺序分配或 redirect 更新。
  pc_t pc_q;
  pc_t pc_d;
  logic boot_pending_q;
  logic frontend_flush;

  // 请求 holding register 在空闲时组合旁路，在 I-cache 反压时保持请求和 payload。
  // request_outstanding_q 仅在请求已经握手、但响应尚未握手的期间置位。
  fetch_req_t fetch_req_data;
  fetch_req_t req_hold_data;
  logic req_hold_ready;
  logic req_hold_valid;
  logic req_hold_flush;
  logic fetch_req_valid;
  logic fetch_req_fire;
  logic imem_req_fire;
  logic imem_rsp_fire;
  logic request_outstanding_q;

  // pending_meta_q 对应唯一一笔已被 I-cache 接收、正在等待响应的请求。
  // held_request_stale_q 对应已经展示给 CoreBus、但 redirect 后尚未握手的
  // u_req_hold 请求；pending_stale_q 对应已经握手的旧路径请求。
  fetch_meta_t pending_meta_q;
  fetch_meta_t response_meta;
  logic pending_stale_q;
  logic held_request_stale_q;
  logic response_stale;

  // 已完成响应先进入非 fall-through FIFO，再驱动 IF/ID。这样命中路径为一拍，
  // 同时 rsp_ready 不会由组合 if_id.valid 反向影响请求 valid。
  if_id_payload_t inst_fifo_data;
  if_id_payload_t if_id_payload;
  logic inst_fifo_ready;
  logic inst_fifo_valid;
  logic inst_fifo_push;
  logic inst_fifo_ready_i;
  logic [63:0] instid_q;

  ////////////////////////
  // 取指请求与响应配对 //
  ////////////////////////

  // redirect 只禁止向 u_req_hold 分配新 PC，已经锁存并对外展示的请求仍须保持。
  assign frontend_flush = redirect.valid;
  assign fetch_req_valid = !boot_pending_q && !frontend_flush;
  assign fetch_req_data = '{pc: pc_q};
  assign fetch_req_fire = fetch_req_valid && req_hold_ready;

  assign imem.req_payload.addr = req_hold_data.pc;
  assign imem.req_payload.write = 1'b0;
  assign imem.req_payload.size = CORE_BUS_SIZE_WORD;
  assign imem.req_payload.wdata = '0;
  assign imem.req_payload.wstrb = '0;
  // 不依赖响应 FIFO ready；这是切断 I-cache hit 路径组合环的关键。
  assign imem.req_valid = req_hold_valid && !request_outstanding_q;
  assign imem_req_fire = imem.req_valid && imem.req_ready;

  // 在无 outstanding 的同拍 hit 情形，响应元数据来自当前 holding request；否则
  // 使用已经锁存的 pending 元数据。instid 在请求握手沿后递增，因此本拍仍是当前 ID。
  assign response_meta = request_outstanding_q ? pending_meta_q :
      '{pc: req_hold_data.pc, instid: instid_q};
  assign response_stale = frontend_flush ||
      (request_outstanding_q ? pending_stale_q : held_request_stale_q);
  // stale 响应无需占用 FIFO，即使 FIFO 满也必须能被接收并丢弃。
  assign imem.rsp_ready = response_stale || inst_fifo_ready;
  assign imem_rsp_fire = imem.rsp_valid && imem.rsp_ready;
  assign inst_fifo_push = imem_rsp_fire && !response_stale;

  // redirect 可直接取消尚未向 CoreBus 展示的预存请求；已经 req_valid 的请求不能
  // 撤销，会由 held_request_stale_q 标记并在后续响应返回时丢弃。
  assign req_hold_flush = frontend_flush && !imem.req_valid;

  always_comb begin
    inst_fifo_data = '0;
    inst_fifo_data.meta.pc = response_meta.pc;
    inst_fifo_data.meta.instr = instr_t'(imem.rsp_payload.rdata);
    inst_fifo_data.meta.instid = response_meta.instid;
    inst_fifo_data.exception.valid = imem.rsp_payload.error;
    inst_fifo_data.exception.cause = imem.rsp_payload.error ? EXC_INST_ACCESS_FAULT :
        exception_cause_e'('0);
    inst_fifo_data.exception.tval = imem.rsp_payload.error ? response_meta.pc : '0;
  end

  ////////////////////
  // IF/ID 接口打包 //
  ////////////////////

  assign if_id.payload = if_id_payload;
  assign if_id.valid = !frontend_flush && inst_fifo_valid;
  assign inst_fifo_ready_i = !frontend_flush && if_id.ready;

  ///////////////////////////////////
  // 请求保持与已返回指令缓冲队列 //
  ///////////////////////////////////

  fall_through_register #(
    .T(fetch_req_t)
  ) u_req_hold (
    .clk_i,
    .rst_ni,
    .flush_i(req_hold_flush),
    .valid_i(fetch_req_valid),
    .ready_o(req_hold_ready),
    .data_i(fetch_req_data),
    .valid_o(req_hold_valid),
    // outstanding 时不允许本地 holding request 再被 I-cache 接收。
    .ready_i(imem.req_ready && !request_outstanding_q),
    .data_o(req_hold_data)
  );

  stream_fifo #(
    .Depth(IfIdQueueDepth),
    .FallThrough(1'b0),
    .SameCycleRW(1'b1),
    .T(if_id_payload_t)
  ) u_inst_fifo (
    .clk_i,
    .rst_ni,
    .flush_i(frontend_flush),
    .usage_o(  /* 未使用 */),
    .data_i(inst_fifo_data),
    .valid_i(inst_fifo_push),
    .ready_o(inst_fifo_ready),
    .data_o(if_id_payload),
    .valid_o(inst_fifo_valid),
    .ready_i(inst_fifo_ready_i)
  );

  //////////////////////////////////////
  // PC、请求元数据与 stale 状态更新 //
  //////////////////////////////////////

  always_comb begin
    // redirect 优先于顺序分配；即使旧请求尚待响应，目标 PC 也可立即保存，待旧
    // 事务排空后由 u_req_hold 重新向 I-cache 发出。
    if (redirect.valid) begin
      pc_d = redirect.payload.target_pc;
    end else if (boot_pending_q) begin
      pc_d = boot_pc_i;
    end else if (fetch_req_fire) begin
      pc_d = pc_q + pc_t'(32'd4);
    end else begin
      pc_d = pc_q;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q <= '0;
      boot_pending_q <= 1'b1;
      request_outstanding_q <= 1'b0;
      pending_meta_q <= '0;
      pending_stale_q <= 1'b0;
      held_request_stale_q <= 1'b0;
      instid_q <= 64'd1;
    end else begin
      pc_q <= pc_d;
      boot_pending_q <= 1'b0;

      if (imem_req_fire) instid_q <= instid_q + 64'd1;

      // 只有“请求已握手且响应尚未同拍返回”才形成 pending 事务。I-cache hit 的
      // 同拍 request/response 不占用该寄存器。
      if (imem_req_fire && !imem_rsp_fire) begin
        request_outstanding_q <= 1'b1;
        pending_meta_q.pc <= req_hold_data.pc;
        pending_meta_q.instid <= instid_q;
        pending_stale_q <= frontend_flush || held_request_stale_q;
      end else if (imem_rsp_fire && request_outstanding_q) begin
        request_outstanding_q <= 1'b0;
        pending_stale_q <= 1'b0;
      end else if (frontend_flush && request_outstanding_q) begin
        pending_stale_q <= 1'b1;
      end

      // 已经展示的 request 在 redirect 后必须保留到握手；尚未展示的 request
      // 则由 req_hold_flush 直接清除。
      if (imem_req_fire) held_request_stale_q <= 1'b0;
      else if (frontend_flush && imem.req_valid) held_request_stale_q <= 1'b1;
      else if (req_hold_flush) held_request_stale_q <= 1'b0;
    end
  end

  ////////////////////
  // 协议与参数断言 //
  ////////////////////

  // verilog_format: off
  `ASSERT_STABLE(
    ImemReqStable,
    imem.req_valid,
    imem.req_ready,
    imem.req_payload,
    '0,
    clk_i,
    !rst_ni,
    "CoreBus request payload must remain stable while valid is waiting for ready."
  )

  `ASSERT(
    ImemReqValidStable,
    imem.req_valid && !imem.req_ready |=> imem.req_valid,
    clk_i,
    !rst_ni,
    "CoreBus request valid must remain asserted until ready."
  )

  `ASSERT(
    NoSecondImemRequestWhileOutstanding,
    request_outstanding_q |-> !imem.req_valid,
    clk_i,
    !rst_ni,
    "IF supports exactly one accepted instruction request awaiting a response."
  )

  `ASSERT(BootPcAligned, boot_pending_q |-> (boot_pc_i[1:0] == 2'b00), clk_i, !rst_ni,
          "boot_pc_i must satisfy RV32I IALIGN=32.")
  `ASSERT_INIT(FetchOutstandingDepthIsOne, FetchOutstandingDepth == 1,
               "The connected I-cache supports at most one outstanding request.")
  // verilog_format: on

endmodule
