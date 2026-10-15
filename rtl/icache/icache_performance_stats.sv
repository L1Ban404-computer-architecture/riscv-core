// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// hit 分类晚一拍出现在 lookup。服务延迟止于 CoreBus 响应首次有效，
// lookup 弹出释放旧事务；尚未响应的 flush 取消不形成延迟样本。
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

  icache_performance_payload_t stats_q;
  logic request_accepted_q;
  logic response_seen_q;
  logic [63:0] request_cycle_q;
  logic [63:0] cycle_q;
  logic sample_response;

  assign sample_response = core_bus.rsp_valid && lookup.valid && !response_seen_q;
  assign performance.payload = stats_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stats_q <= '0;
      request_accepted_q <= 1'b0;
      response_seen_q <= 1'b0;
      request_cycle_q <= '0;
      cycle_q <= '0;
    end else begin
      // 请求接受后一拍，lookup 才提供这笔请求的命中分类。
      if (request_accepted_q) begin
        stats_q.request_count <= stats_q.request_count + 64'd1;
        if (lookup.payload.hit)
          stats_q.hit_count <= stats_q.hit_count + 64'd1;
      end
      if (sample_response) begin
        if (lookup.payload.hit) begin
          stats_q.hit_response_count <= stats_q.hit_response_count + 64'd1;
          stats_q.hit_latency_cycle_sum <= stats_q.hit_latency_cycle_sum + (cycle_q - request_cycle_q);
        end else begin
          stats_q.miss_response_count <= stats_q.miss_response_count + 64'd1;
          stats_q.miss_latency_cycle_sum <= stats_q.miss_latency_cycle_sum + (cycle_q - request_cycle_q);
        end
      end

      // lookup 保存在途事务；这里只保存时间戳和是否已采样。新请求优先，
      // 避免旧 lookup 弹出时清掉同拍接受的新请求。
      cycle_q <= cycle_q + 64'd1;
      request_accepted_q <= core_bus.req_fire;
      if (core_bus.req_fire) begin
        request_cycle_q <= cycle_q;
        response_seen_q <= 1'b0;
      end else if (lookup.fire) begin
        response_seen_q <= 1'b0;
      end else if (sample_response) begin
        response_seen_q <= 1'b1;
      end
    end
  end

endmodule
`endif
