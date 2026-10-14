// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 请求的 hit 分类晚一拍出现在 lookup，时间戳仍用接受当拍。
// lookup 弹出即事务结束，包含正常回应和 flush 取消。
`ifndef SYNTHESIS
module icache_performance_stats
  import icache_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  core_bus_if.monitor core_bus,
  icache_lookup_if.monitor lookup,
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

      if (req_accepted_q) begin
        stats_q.request_count <= stats_q.request_count + 64'd1;
        if (lookup.payload.hit) begin
          stats_q.hit_count <= stats_q.hit_count + 64'd1;
          stats_q.hit_request_cycle_sum <= stats_q.hit_request_cycle_sum + 128'(req_cycle_q);
        end else begin
          stats_q.miss_request_cycle_sum <= stats_q.miss_request_cycle_sum + 128'(req_cycle_q);
        end
      end
      if (lookup.fire) begin
        if (lookup.payload.hit) begin
          stats_q.hit_response_cycle_sum <= stats_q.hit_response_cycle_sum + 128'(cycle_q);
        end else begin
          stats_q.miss_response_cycle_sum <= stats_q.miss_response_cycle_sum + 128'(cycle_q);
        end
      end
    end
  end

endmodule
`endif
