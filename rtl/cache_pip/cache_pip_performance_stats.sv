// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 流水线 I-cache 事务统计。只观察 CoreBus、lookup 和 refill，不驱动通路。
//
// 请求接受当拍 lookup 里仍是上一笔结果，本笔 hit 要到下一拍才出现在 lookup。
// 因此请求计数晚一拍入账，但时间戳用接受当拍的周期。响应当拍 lookup 就是正在
// 弹出的那笔事务，直接用它的 hit 分类。字段与阻塞式 I-cache 相同。
`ifndef SYNTHESIS
`include "common/assertions.svh"

module cache_pip_performance_stats
  import icache_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  core_bus_if.monitor core_bus,
  cache_lookup_if.monitor lookup,
  cache_refill_if.monitor refill,
  icache_performance_debug_if.producer performance
);

  logic req_accepted_q;
  logic [63:0] req_cycle_q;
  logic [63:0] cycle_q;
  icache_performance_payload_t stats_q;

  assign performance.payload = stats_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_accepted_q <= 1'b0;
      req_cycle_q <= '0;
      cycle_q <= '0;
      stats_q <= '0;
    end else begin
      cycle_q <= cycle_q + 64'd1;
      req_accepted_q <= core_bus.req_fire;
      if (core_bus.req_fire) req_cycle_q <= cycle_q;

      // req_accepted_q 对应上一拍接受的请求，这一拍 lookup 已换成该请求。
      if (req_accepted_q) begin
        stats_q.request_count <= stats_q.request_count + 64'd1;
        if (lookup.payload.hit) begin
          stats_q.hit_count <= stats_q.hit_count + 64'd1;
          stats_q.hit_request_cycle_sum <= stats_q.hit_request_cycle_sum + 128'(req_cycle_q);
        end else begin
          stats_q.miss_request_cycle_sum <= stats_q.miss_request_cycle_sum + 128'(req_cycle_q);
        end
      end
      if (core_bus.rsp_fire) begin
        if (lookup.payload.hit) begin
          stats_q.hit_response_cycle_sum <= stats_q.hit_response_cycle_sum + 128'(cycle_q);
        end else begin
          stats_q.miss_response_cycle_sum <= stats_q.miss_response_cycle_sum + 128'(cycle_q);
        end
      end
    end
  end

  `ASSERT(CachePipPerfAcceptedVisible, req_accepted_q |-> lookup.valid, clk_i, !rst_ni,
          "The request accepted last cycle must now be visible on lookup.")
  `ASSERT(CachePipPerfResponseVisible, core_bus.rsp_fire |-> lookup.valid, clk_i, !rst_ni,
          "A response must belong to the lookup entry being popped.")
  `ASSERT(CachePipPerfMissStartsRefill, req_accepted_q && !lookup.payload.hit |-> refill.addr_valid,
          clk_i, !rst_ni, "A miss must present its refill address on the classification cycle.")
  `ASSERT(CachePipPerfHitSkipsRefill, req_accepted_q && lookup.payload.hit |-> !refill.addr_valid,
          clk_i, !rst_ni, "A hit must not start a refill.")

endmodule
`endif
