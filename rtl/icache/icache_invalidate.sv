// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 锁存失效请求并挡住新查询，已有 lookup 和背景回填排空后清除有效位。
// invalidate_i 持续为高时保持阻塞；空闲后可以持续清除，直到请求撤销。

module icache_invalidate (
  // 全局控制与失效请求
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,

  // 只观察在途事务是否还占用阵列。lookup 为高表示还有一笔请求尚未回应。
  input logic lookup_valid_i,
  input logic refill_valid_i,

  // 上游请求与送往阵列的请求。清除期间过滤尚未握手的请求。
  core_bus_if.req_slave core_bus,
  core_bus_if.req_master array_req,

  // 阵列有效位清除脉冲
  output logic invalidate_apply_o
);

  logic pending_q;
  logic block_req;

  // 请求到达的当拍就挡住后续握手，避免它在清除前进入 lookup。
  assign block_req = pending_q || invalidate_i;
  assign array_req.req_valid = core_bus.req_valid && !block_req;
  assign array_req.req_payload = core_bus.req_payload;
  assign core_bus.req_ready = array_req.req_ready && !block_req;
  assign invalidate_apply_o = pending_q && !lookup_valid_i && !refill_valid_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q <= 1'b0;
    end else begin
      pending_q <= invalidate_i || (pending_q && !invalidate_apply_o);
    end
  end

`ifndef SYNTHESIS
  // 上一拍已经锁存、且尚未实施的失效，这一拍必须仍为 pending。
  logic pending_hold_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) pending_hold_q <= 1'b0;
    else pending_hold_q <= pending_q && !invalidate_apply_o;
  end

  ICacheInvalidateApplyWhenIdle: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !invalidate_apply_o || (!lookup_valid_i && !refill_valid_i)));
  ICacheInvalidatePendingStable: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !pending_hold_q || pending_q));
`endif

endmodule
