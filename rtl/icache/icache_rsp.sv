// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 返回 lookup 命中或 miss 首拍。flush 取消旧 lookup，已发出的 miss 单独排空。
module icache_rsp (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  icache_lookup_if.consumer lookup,
  icache_miss_if.master miss,
  core_bus_if.rsp_source core_bus
);

  logic lookup_hit;
  // 只描述首字响应的所有权；背景回填由 icache_miss 独立管理。
  typedef enum logic [1:0] {
    ResponseNone,
    ResponsePending,
    ResponseDiscard
  } response_state_e;
  response_state_e response_state_q;
  logic miss_response_visible;

  // flush 直接取消尚未发出的 miss；已接受的 miss 要等首拍回应才能释放。
  assign miss.req_valid = lookup.valid && !lookup.payload.hit && !flush_i &&
      (response_state_q == ResponseNone);
  assign miss.req_payload.addr = lookup.payload.addr;

  // 丢弃旧 miss 不受 CPU 背压影响；新 lookup 的命中仍可正常返回。
  assign lookup_hit = lookup.valid && lookup.payload.hit;
  assign miss_response_visible = miss.rsp_valid && (response_state_q == ResponsePending);
  assign core_bus.rsp_valid = !flush_i && (lookup_hit || miss_response_visible);
  assign core_bus.rsp_payload = '{
    rdata: lookup_hit ? lookup.payload.rdata : miss.rsp_payload.rdata,
    error: lookup_hit ? 1'b0 : miss.rsp_payload.error
  };
  assign miss.rsp_ready = core_bus.rsp_ready || flush_i ||
      (response_state_q == ResponseDiscard);
  assign lookup.ready = core_bus.rsp_fire || flush_i;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) response_state_q <= ResponseNone;
    else if (miss.rsp_fire) response_state_q <= ResponseNone;
    else if (miss.req_fire) response_state_q <= ResponsePending;
    else if (flush_i && (response_state_q == ResponsePending))
      response_state_q <= ResponseDiscard;
  end

`ifndef SYNTHESIS
  ICacheMissResponseOwned:
  assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !miss.rsp_valid || (response_state_q != ResponseNone)));
`endif

endmodule
