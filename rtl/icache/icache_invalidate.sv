// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 流水线 I-cache 的失效控制，不参与命中、缺失或回填的数据通路。
//
// `invalidate_i` 锁存为 pending。pending 期间只禁止新的请求握手；已经进入 lookup
// 的请求仍由原响应通路回应，内容保持进入时的结果，不因为失效而重读阵列。lookup
// 排空且 refill 地址已经撤销后，再向阵列给出一拍清除。`invalidate_i` 保持为高时
// pending 不释放，新请求继续被挡住。

module icache_invalidate (
  // 全局控制与失效请求
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,

  // 只观察在途事务是否还占用阵列。lookup 为高表示还有一笔请求尚未回应。
  input logic lookup_valid_i,
  input logic refill_addr_valid_i,

  // 禁止新的请求握手，以及阵列有效位清除脉冲
  output logic block_req_o,
  output logic invalidate_apply_o
);

  logic pending_q;

  // 请求到达的当拍就挡住后续握手，避免它在清除前进入 lookup。
  assign block_req_o = pending_q || invalidate_i;
  assign invalidate_apply_o = pending_q && !lookup_valid_i && !refill_addr_valid_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q <= 1'b0;
    end else if (invalidate_apply_o) begin
      pending_q <= invalidate_i;
    end else if (invalidate_i) begin
      pending_q <= 1'b1;
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
      !invalidate_apply_o || (!lookup_valid_i && !refill_addr_valid_i)));
  ICacheInvalidatePendingStable: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !pending_hold_q || pending_q));
`endif

endmodule
