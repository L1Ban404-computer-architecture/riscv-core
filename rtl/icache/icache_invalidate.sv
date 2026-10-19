// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 失效期间阻止新查询，lookup 和回填排空后清除阵列。
module icache_invalidate (
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,

  input logic lookup_valid_i,
  input logic refill_valid_i,

  core_bus_if.req_slave core_bus,
  core_bus_if.req_master array_req,

  output logic invalidate_apply_o
);

  logic pending_q;
  logic block_req;

  // 当拍就阻止新请求，锁存后等待已有事务排空。
  assign block_req = invalidate_i || pending_q;
  assign invalidate_apply_o = pending_q && !lookup_valid_i && !refill_valid_i;
  assign array_req.req_valid = core_bus.req_valid && !block_req;
  assign array_req.req_payload = core_bus.req_payload;
  assign core_bus.req_ready = array_req.req_ready && !block_req;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q <= 1'b0;
    end else begin
      pending_q <= invalidate_i || (pending_q && !invalidate_apply_o);
    end
  end

`ifndef SYNTHESIS
  ICacheInvalidateApplyWhenIdle: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !invalidate_apply_o || (!lookup_valid_i && !refill_valid_i)));
`endif

endmodule
