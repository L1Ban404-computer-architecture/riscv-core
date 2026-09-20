// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// I-cache 事务统计。只观察已有 CoreBus / lookup / refill 的 monitor，不驱动通路。
// 命中由请求接受当拍的 lookup.hit 分类；响应用观察器内在途记录，不要求同拍握手。
// 仿真端按命中/缺失事务数计算平均延迟，不修正未完成请求。
`ifndef SYNTHESIS
`include "common/assertions.svh"

module icache_performance_stats
  import icache_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  core_bus_if.monitor core_bus,
  icache_lookup_if.monitor lookup,
  icache_refill_if.monitor refill,
  icache_performance_debug_if.producer performance
);
  logic request_hit;
  logic response_hit;
  logic outstanding_hit_q;
  logic [63:0] cycle_q;
  icache_performance_payload_t stats_q;

  assign performance.payload = stats_q;
  assign request_hit = lookup.rsp_payload.hit;
  assign response_hit = core_bus.req_fire ? lookup.rsp_payload.hit : outstanding_hit_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      outstanding_hit_q <= 1'b0;
      cycle_q <= '0;
      stats_q <= '0;
    end else begin
      cycle_q <= cycle_q + 64'd1;
      if (core_bus.req_fire) outstanding_hit_q <= lookup.rsp_payload.hit;
      if (core_bus.req_fire) begin
        stats_q.request_count <= stats_q.request_count + 64'd1;
        if (request_hit) begin
          stats_q.hit_count <= stats_q.hit_count + 64'd1;
          stats_q.hit_request_cycle_sum <= stats_q.hit_request_cycle_sum + 128'(cycle_q);
        end else begin
          stats_q.miss_request_cycle_sum <= stats_q.miss_request_cycle_sum + 128'(cycle_q);
        end
      end
      if (core_bus.rsp_fire) begin
        if (response_hit) begin
          stats_q.hit_response_cycle_sum <= stats_q.hit_response_cycle_sum + 128'(cycle_q);
        end else begin
          stats_q.miss_response_cycle_sum <= stats_q.miss_response_cycle_sum + 128'(cycle_q);
        end
      end
    end
  end

  `ASSERT(ICachePerfMissBegin,
          core_bus.req_fire && !lookup.rsp_payload.hit |-> refill.begin_valid, clk_i, !rst_ni)
  `ASSERT(ICachePerfHitNotBegin,
          core_bus.req_fire && lookup.rsp_payload.hit |-> !refill.begin_valid, clk_i, !rst_ni)

endmodule
`endif
