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

  // redirect_i 只来自 EX stage。它表示“前端改道”，用于丢弃尚未进入 EX
  // 的年轻事务；它不负责冲刷 EX/MEM/WB 中已经有效的指令。
  input redirect_bus_t redirect_i,

  // CoreBus 取指接口。IF 只发出 wstrb=0 的固定字宽读请求，读请求和
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
    logic epoch;
  } fetch_req_t;

  // pc_q 是下一次准备发出的取指 PC。boot_pc_i 在复位释放后的第一个周期
  // 被采样，后续 PC 只由顺序取指或 redirect 更新。
  pc_t pc_q;
  pc_t pc_d;
  logic boot_pending_q;
  logic boot_pending_d;
  logic fetch_epoch_q;
  logic fetch_epoch_d;

  // 请求 holding register 使用本地 fall_through_register。redirect 只
  // 阻止新请求进入 holding register；如果请求已经在时钟沿被接收端采样
  // 为 valid 且尚未 ready，fall-through register 会锁住它，满足
  // CoreBus valid 不能撤销的同步约束。
  fetch_req_t fetch_req_data;
  fetch_req_t req_hold_data;
  logic req_hold_ready;
  logic req_hold_valid;
  logic req_hold_clr;
  logic fetch_req_valid;
  logic fetch_req_fire;

  // PC FIFO 由本地 stream_fifo 实现，记录已经完成请求握手、
  // 但尚未收到响应的请求 PC 及其 epoch。它使用 fall-through 模式，
  // 支持无延迟存储器在请求握手同周期给出响应。redirect 翻转 epoch。
  // 这里使用 1 bit epoch 的前提是：IF 只使用单条顺序 CoreBus 请求流，响应
  // 必须严格按请求握手顺序返回；redirect 只来自 EX，下一次 redirect 必须
  // 等新路径指令返回并进入 EX 后才可能发生。因此在 epoch 再次翻转前，
  // 更老 epoch 的响应已经按顺序被消费掉，不会和当前路径混淆。
  fetch_req_t pc_fifo_data;
  logic pc_fifo_ready;
  logic pc_fifo_valid;
  logic pc_fifo_input_valid;

  // fetch FIFO 同样使用 stream_fifo，保存已经配对完成的 {pc, instr}。
  // 它直接驱动 IF -> ID valid/ready 通道，ID stage 只消费完整 fetch 事务。
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
  assign fetch_req_valid = !boot_pending_q && !redirect_i.valid;
  assign fetch_req_data = '{pc: pc_q, epoch: fetch_epoch_q};
  assign fetch_req_fire = fetch_req_valid && req_hold_ready;

  assign imem_req_o.req.addr = req_hold_data.pc;
  assign imem_req_o.req.wdata = '0;
  assign imem_req_o.req.wstrb = '0;
  assign imem_req_o.req_valid = req_hold_valid && pc_fifo_ready;
  // valid_i 不依赖 pc_fifo_ready；stream_fifo 内部再与 ready_o 相与得到的
  // push 事件与 imem_req_fire 完全一致，从而避免满载交接路径形成组合环。
  assign pc_fifo_input_valid = req_hold_valid && imem_resp_i.req_ready;

  // redirect 可以丢弃尚未向 CoreBus 暴露的预存请求；已经拉高 req_valid 的
  // 请求必须继续保持，直到从设备接受。
  assign req_hold_clr = redirect_i.valid && !imem_req_o.req_valid;

  // 返回端按 CoreBus 顺序从 PC FIFO 头部取对应 PC。如果该请求 epoch
  // 与当前 epoch 不同，说明它属于 redirect 前的旧路径，只弹出不写入。
  assign returned_fetch_kept = (pc_fifo_data.epoch == fetch_epoch_q) && !redirect_i.valid;
  assign imem_req_o.rsp_ready = pc_fifo_valid && (!returned_fetch_kept || fetch_fifo_ready);
  assign imem_rsp_fire = imem_resp_i.rsp_valid && imem_req_o.rsp_ready;
  assign fetch_fifo_push = imem_rsp_fire && returned_fetch_kept;

  assign fetch_fifo_data.fetch.pc = pc_fifo_data.pc;
  assign fetch_fifo_data.fetch.instr = instr_t'(imem_resp_i.rsp.rdata);
  assign fetch_fifo_data.debug.fetch.pc = pc_fifo_data.pc;
  assign fetch_fifo_data.debug.fetch.instr = instr_t'(imem_resp_i.rsp.rdata);

  // fetch FIFO 在 redirect 周期同步清空；组合输出也用 redirect_i.valid 屏蔽，
  // 避免同周期把旧路径指令继续交给 ID。
  assign if_id_valid_o = !redirect_i.valid && fetch_fifo_valid;
  assign fetch_fifo_ready_i = !redirect_i.valid && if_id_ready_i;

  fall_through_register #(
    .T(fetch_req_t)
  ) u_req_hold (
    .clk_i,
    .rst_ni,
    .clr_i(req_hold_clr),
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
    .usage_o(  /* unused */),
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
    .SameCycleRW(1'b1),
    .T(if_id_bus_t)
  ) u_fetch_fifo (
    .clk_i,
    .rst_ni,
    .flush_i(redirect_i.valid),
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
    // CoreBus 读请求留在 PC FIFO 中，后续返回时通过 epoch 判断并丢弃旧路径。
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
  assign fetch_epoch_d = redirect_i.valid ? ~fetch_epoch_q : fetch_epoch_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q <= '0;
      boot_pending_q <= 1'b1;
      fetch_epoch_q <= 1'b0;
    end else begin
      pc_q <= pc_d;
      boot_pending_q <= boot_pending_d;
      fetch_epoch_q <= fetch_epoch_d;
    end
  end

  // verilog_format: off
  `ASSERT_STABLE(
    ImemReqStable,
    imem_req_o.req_valid,
    imem_resp_i.req_ready,
    imem_req_o.req,
    core_bus_req_chan_t'(0),
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
  // verilog_format: on

endmodule
