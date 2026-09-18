// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// I-cache CoreBus 事件统计，只观察握手，不驱动事务通路。
// 同拍请求与响应记为命中；仅请求或仅响应分别累计缺失时刻。
// 仿真端按命中/缺失事务数计算平均延迟，不修正未完成请求。
`ifndef SYNTHESIS
module icache_performance_stats
  import icache_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  input logic req_valid_i,
  input logic req_ready_i,
  input logic rsp_valid_i,
  input logic rsp_ready_i,
  icache_performance_debug_if.producer performance
);
  logic request_fire;
  logic response_fire;
  logic [63:0] cycle_q;
  icache_performance_payload_t stats_q;

  assign performance.payload = stats_q;
  assign request_fire = req_valid_i && req_ready_i;
  assign response_fire = rsp_valid_i && rsp_ready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cycle_q <= '0;
      stats_q <= '0;
    end else begin
      cycle_q <= cycle_q + 64'd1;
      if (request_fire) begin
        stats_q.request_count <= stats_q.request_count + 64'd1;
        if (response_fire) begin
          stats_q.hit_count <= stats_q.hit_count + 64'd1;
          stats_q.hit_request_cycle_sum <= stats_q.hit_request_cycle_sum + 128'(cycle_q);
          stats_q.hit_response_cycle_sum <= stats_q.hit_response_cycle_sum + 128'(cycle_q);
        end else begin
          stats_q.miss_request_cycle_sum <= stats_q.miss_request_cycle_sum + 128'(cycle_q);
        end
      end else if (response_fire) begin
        stats_q.miss_response_cycle_sum <= stats_q.miss_response_cycle_sum + 128'(cycle_q);
      end
    end
  end

endmodule
`endif
