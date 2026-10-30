// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// lookup 保存响应归属；取消后先排空 miss 首字，再允许接收新 lookup。
module icache_rsp (
  input logic clk_i,
  input logic rst_ni,
  input logic miss_allowed_i,
  output logic lookup_block_o,

  icache_lookup_if.consumer lookup,
  icache_miss_if.master miss,
  core_bus_if.rsp_source core_bus
);

  logic lookup_hit;
  // 仅记录已启动、首字尚未消费的 miss；背景回填由 icache_miss 独立管理。
  logic miss_pending_q;

  // 等待许可时由 lookup 保持请求，不分配回填；命中仍可直接回应。
  // lookup 在 flush 当拍即无效，即使此时 EX 已空也不能启动旧 miss。
  // req_fire 后请求归 miss 控制器所有，许可撤销不影响 AR 或回填排空。
  assign miss.req_valid = lookup.valid && !lookup.payload.hit && miss_allowed_i && !miss_pending_q;
  assign miss.req_payload.addr = lookup.payload.addr;

  // 取消后 lookup 为空。旧首字不受 CPU 背压影响地排空，期间禁止装入新 lookup，
  // 因此 lookup.valid 即可表达响应归属，无需额外的 discard 状态。
  assign lookup_block_o = miss_pending_q && !lookup.valid;
  assign lookup_hit = lookup.valid && lookup.payload.hit;
  assign core_bus.rsp_valid = lookup.valid &&
      (lookup.payload.hit || (miss_pending_q && miss.rsp_valid));
  assign core_bus.rsp_payload = '{
    rdata: lookup_hit ? lookup.payload.rdata : miss.rsp_payload.rdata,
    error: lookup_hit ? 1'b0 : miss.rsp_payload.error
  };
  assign miss.rsp_ready = core_bus.rsp_ready || !lookup.valid;
  assign lookup.ready = core_bus.rsp_fire;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) miss_pending_q <= 1'b0;
    else if (miss.rsp_fire) miss_pending_q <= 1'b0;
    else if (miss.req_fire) miss_pending_q <= 1'b1;
  end

`ifndef SYNTHESIS
  ICacheMissStartsWhenAllowed:
  assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !miss.req_fire || (miss_allowed_i && lookup.valid)));

  ICacheMissResponseOwned:
  assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !miss.rsp_valid || miss_pending_q));

  ICachePendingLookupIsMiss:
  assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !miss_pending_q || !lookup.valid || !lookup.payload.hit));
`endif

endmodule
