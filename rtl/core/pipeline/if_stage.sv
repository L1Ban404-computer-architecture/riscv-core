// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

`include "common/assertions.svh"

module if_stage #(
  // 取指前端允许同时挂起的 CoreBus 读请求数。这个深度主要吸收外部
  // 指令存储器延迟，越大越能保持请求端不断流。
  parameter int unsigned FetchOutstandingDepth = 1,
  // IF -> ID 已返回指令队列深度。这个深度主要吸收 ID stage 的短暂停顿，
  // 不需要和 outstanding 请求深度相同。
  parameter int unsigned IfIdQueueDepth = 2
) (
  input logic clk_i,
  input logic rst_ni,

  // boot_pc_i 是 IF stage 内部 PC 队列的初始值。真实 PC 寄存器墙会放在
  // IF stage 内部，而不是由 riscv_core 顶层额外插入 pipeline_regs。
  input pc_t boot_pc_i,

  // redirect_i 只描述改道目标。IF 在内部由 redirect.valid 派生
  // frontend_flush，使 PC 更新与旧路径事务作废保持原子。
  input redirect_bus_t redirect_i,

  // CoreBus 取指接口。IF 只发出固定字宽读请求，读请求和
  // 顺序响应通过内部 FIFO 解耦。
  output core_bus_req_t imem_req_o,
  input core_bus_resp_t imem_resp_i,

  // IF -> ID 事务通道。if_id 的寄存器墙/FIFO 属于 IF stage 内部。
  output logic if_id_valid_o,
  input logic if_id_ready_i,
  output if_id_bus_t if_id_bus_o
);

  typedef struct packed {
    pc_t pc;
  } fetch_req_t;

  localparam int unsigned FetchCountW =
      (FetchOutstandingDepth > 1) ? $clog2(FetchOutstandingDepth + 1) : 1;
  typedef logic [FetchCountW-1:0] fetch_count_t;

  // pc_q 是下一次准备发出的取指 PC。boot_pc_i 在复位释放后的第一个周期
  // 被采样，后续 PC 只由顺序取指或 redirect 更新。
  pc_t pc_q;
  pc_t pc_d;
  logic boot_pending_q;
  logic boot_pending_d;
  logic frontend_flush;

  // 请求 holding register 使用本地 fall_through_register。redirect 只
  // 阻止新请求进入 holding register；如果请求已经在时钟沿被接收端采样
  // 为 valid 且尚未 ready，fall-through register 会锁住它，满足
  // CoreBus valid 不能撤销的同步约束。
  fetch_req_t fetch_req_data;
  fetch_req_t req_hold_data;
  logic req_hold_ready;
  logic req_hold_valid;
  logic req_hold_flush;
  logic fetch_req_valid;
  logic fetch_req_fire;
  logic imem_req_fire;
  logic held_request_stale_q;

  // PC FIFO 记录已经完成请求握手、但尚未收到响应的请求 PC。CoreBus 响应
  // 严格有序，因此 redirect 只需记录队首有多少响应应被丢弃，无需有限宽度 epoch。
  fetch_req_t pc_fifo_data;
  logic pc_fifo_ready;
  logic pc_fifo_valid;
  logic pc_fifo_input_valid;
  fetch_count_t pc_fifo_usage;
  fetch_count_t pc_fifo_usage_next;
  fetch_count_t discard_count_q;
  fetch_count_t discard_count_d;
  logic pc_fifo_push_stored;
  logic pc_fifo_pop_stored;
  logic returned_fetch_stale;

  // fetch FIFO 同样使用 stream_fifo，保存已经配对完成的 {pc, instr}。
  // 它直接驱动 IF -> ID valid/ready 通道，ID stage 只消费完整 fetch 事务。
  // 这里关闭满队列同周期 pop/push，切断 ID ready 到 CoreBus 响应 ready 的
  // 组合路径；队列满载交接时允许产生一个周期的响应背压。
  if_id_bus_t fetch_fifo_data;
  logic fetch_fifo_ready;
  logic fetch_fifo_valid;
  logic fetch_fifo_ready_i;

  logic imem_rsp_fire;
  logic fetch_fifo_push;
  logic returned_fetch_kept;

  // 请求生成端只决定是否把一个新 PC 分配给 holding register。
  // redirect 不能直接拉低已经锁存的 req_valid，否则会破坏 CoreBus 保持规则。
  // holding register 可以在 PC FIFO 满时提前保存下一条顺序请求。真正的
  // CoreBus valid 仍由 pc_fifo_ready 门控，确保请求握手和元数据入队原子发生。
  assign frontend_flush = redirect_i.valid;
  assign fetch_req_valid = !boot_pending_q && !frontend_flush;
  assign fetch_req_data = '{pc: pc_q};
  assign fetch_req_fire = fetch_req_valid && req_hold_ready;

  assign imem_req_o.addr = req_hold_data.pc;
  assign imem_req_o.write = 1'b0;
  assign imem_req_o.size = MEM_SIZE_WORD;
  assign imem_req_o.wdata = '0;
  assign imem_req_o.wstrb = '0;
  assign imem_req_o.req_valid = req_hold_valid && pc_fifo_ready;
  // valid_i 不依赖 pc_fifo_ready；stream_fifo 内部再与 ready_o 相与得到的
  // push 事件与 imem_req_fire 完全一致，从而避免满载交接路径形成组合环。
  assign pc_fifo_input_valid = req_hold_valid && imem_resp_i.req_ready;
  assign imem_req_fire = imem_req_o.req_valid && imem_resp_i.req_ready;

  // redirect 可以丢弃尚未向 CoreBus 暴露的预存请求；已经拉高 req_valid 的
  // 请求必须继续保持，直到从设备接受。
  assign req_hold_flush = frontend_flush && !imem_req_o.req_valid;

  // discard_count_q 覆盖 FIFO 中已经接受的旧路径请求；held_request_stale_q
  // 覆盖 redirect 时已经锁存、但尚未完成请求握手的请求。
  assign returned_fetch_stale = (discard_count_q != '0) ||
      ((pc_fifo_usage == '0) && held_request_stale_q);
  assign returned_fetch_kept = !returned_fetch_stale && !frontend_flush;
  assign imem_req_o.rsp_ready = pc_fifo_valid && (!returned_fetch_kept || fetch_fifo_ready);
  assign imem_rsp_fire = imem_resp_i.rsp_valid && imem_req_o.rsp_ready;
  assign fetch_fifo_push = imem_rsp_fire && returned_fetch_kept;

  // 计算时钟沿之后真正存入 FIFO 的请求数量。空 FIFO 的零延迟请求/响应
  // 会走 fall-through bypass，不形成存储条目。
  assign pc_fifo_push_stored = imem_req_fire &&
      !((pc_fifo_usage == '0) && imem_rsp_fire);
  assign pc_fifo_pop_stored = imem_rsp_fire && (pc_fifo_usage != '0);
  always_comb begin
    pc_fifo_usage_next = pc_fifo_usage;
    unique case ({pc_fifo_push_stored, pc_fifo_pop_stored})
      2'b10: pc_fifo_usage_next = pc_fifo_usage + fetch_count_t'(1);
      2'b01: pc_fifo_usage_next = pc_fifo_usage - fetch_count_t'(1);
      default: ;
    endcase

    discard_count_d = discard_count_q;
    if ((discard_count_q != '0) && pc_fifo_pop_stored)
      discard_count_d = discard_count_q - fetch_count_t'(1);
    if (held_request_stale_q && pc_fifo_push_stored)
      discard_count_d = discard_count_d + fetch_count_t'(1);

    // redirect 使时钟沿后仍在队列中的全部请求失效。重复 redirect 只是重新
    // 覆盖当前队列用量，不会出现 epoch 翻转回旧值的问题。
    if (frontend_flush) discard_count_d = pc_fifo_usage_next;
  end

  always_comb begin
    fetch_fifo_data = '0;
    fetch_fifo_data.pc = pc_fifo_data.pc;
    fetch_fifo_data.instr = instr_t'(imem_resp_i.rdata);
    fetch_fifo_data.exception.valid = imem_resp_i.error;
    fetch_fifo_data.exception.cause = imem_resp_i.error ? EXC_INST_ACCESS_FAULT :
        exception_cause_e'('0);
    fetch_fifo_data.exception.tval = imem_resp_i.error ? pc_fifo_data.pc : '0;
    fetch_fifo_data.debug.pc = pc_fifo_data.pc;
    fetch_fifo_data.debug.instr = instr_t'(imem_resp_i.rdata);
  end

  // fetch FIFO 在 frontend flush 周期同步清空；组合输出同时屏蔽，
  // 避免同周期把旧路径指令继续交给 ID。
  assign if_id_valid_o = !frontend_flush && fetch_fifo_valid;
  assign fetch_fifo_ready_i = !frontend_flush && if_id_ready_i;

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
    .ready_i(imem_resp_i.req_ready && pc_fifo_ready),
    .data_o(req_hold_data)
  );

  stream_fifo #(
    .Depth(FetchOutstandingDepth),
    .FallThrough(1'b1),
    .SameCycleRW(1'b1),
    .T(fetch_req_t)
  ) u_pc_fifo (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .usage_o(pc_fifo_usage),
    .data_i(req_hold_data),
    .valid_i(pc_fifo_input_valid),
    .ready_o(pc_fifo_ready),
    .data_o(pc_fifo_data),
    .valid_o(pc_fifo_valid),
    .ready_i(imem_rsp_fire)
  );

  stream_fifo #(
    .Depth(IfIdQueueDepth),
    .FallThrough(1'b0),
    .SameCycleRW(1'b0),
    .T(if_id_bus_t)
  ) u_fetch_fifo (
    .clk_i,
    .rst_ni,
    .flush_i(frontend_flush),
    .usage_o(  /* unused */),
    .data_i(fetch_fifo_data),
    .valid_i(fetch_fifo_push),
    .ready_o(fetch_fifo_ready),
    .data_o(if_id_bus_o),
    .valid_o(fetch_fifo_valid),
    .ready_i(fetch_fifo_ready_i)
  );

  always_comb begin
    // redirect 优先于顺序取指。fetch FIFO 由 flush_i 清空；已经发出的
    // CoreBus 读请求留在 PC FIFO 中，后续返回时按待丢弃响应计数清除旧路径。
    if (redirect_i.valid) begin
      pc_d = redirect_i.target_pc;
    end else if (boot_pending_q) begin
      pc_d = boot_pc_i;
    end else if (fetch_req_fire) begin
      pc_d = pc_q + pc_t'(32'd4);
    end else begin
      pc_d = pc_q;
    end
  end

  // boot_pending_q 只用于复位释放后的第一个正常周期同步采样 boot_pc_i。
  // reset 后它为 1，下一拍无条件清 0。
  assign boot_pending_d = 1'b0;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q <= '0;
      boot_pending_q <= 1'b1;
      discard_count_q <= '0;
      held_request_stale_q <= 1'b0;
    end else begin
      pc_q <= pc_d;
      boot_pending_q <= boot_pending_d;
      discard_count_q <= discard_count_d;
      if (imem_req_fire)
        held_request_stale_q <= 1'b0;
      else if (frontend_flush && imem_req_o.req_valid)
        held_request_stale_q <= 1'b1;
      else if (req_hold_flush)
        held_request_stale_q <= 1'b0;
    end
  end

  // verilog_format: off
  `ASSERT_STABLE(
    ImemReqStable,
    imem_req_o.req_valid,
    imem_resp_i.req_ready,
    {imem_req_o.addr, imem_req_o.write, imem_req_o.size, imem_req_o.wdata, imem_req_o.wstrb},
    '0,
    clk_i,
    !rst_ni,
    "CoreBus request payload must remain stable while valid is waiting for ready."
  )

  `ASSERT(
    ImemReqValidStable,
    imem_req_o.req_valid && !imem_resp_i.req_ready |=> imem_req_o.req_valid,
    clk_i,
    !rst_ni,
    "CoreBus request valid must remain asserted until ready."
  )

  `ASSERT(BootPcAligned, boot_pending_q |-> (boot_pc_i[1:0] == 2'b00), clk_i, !rst_ni,
          "boot_pc_i must satisfy RV32I IALIGN=32.")
  // verilog_format: on

endmodule
