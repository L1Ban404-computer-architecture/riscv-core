// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 服务延迟从请求接受到响应首次有效；响应背压单独计数。
// flush 只取消旧请求，同拍接受的新请求仍保留。数据侧 flush 接 0。
`ifndef SYNTHESIS
module memory_performance_stats
  import riscv_debug_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic [63:0] cycle_i,
  input riscv_bus_pkg::bus_debug_payload_t bus_i,
  output memory_performance_payload_t stats_o
);
  memory_performance_payload_t stats_q;
  logic waiting_q;
  logic response_seen_q;
  logic [63:0] request_cycle_q;
  logic sample_response;
  logic zero_cycle_response;
  logic req_fire, rsp_fire;

  assign req_fire = bus_i.req_valid && bus_i.req_ready;
  assign rsp_fire = bus_i.rsp_valid && bus_i.rsp_ready;

  // 有旧请求时响应归属旧请求；否则请求和响应同拍表示零周期服务。
  assign zero_cycle_response = !waiting_q && req_fire && bus_i.rsp_valid;
  assign sample_response = bus_i.rsp_valid && !flush_i &&
      (waiting_q ? !response_seen_q : req_fire);
  assign stats_o = stats_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      stats_q <= '0;
      waiting_q <= 1'b0;
      response_seen_q <= 1'b0;
      request_cycle_q <= '0;
    end else begin
      if (sample_response) begin
        stats_q.response_count <= stats_q.response_count + 64'd1;
        stats_q.latency_cycle_sum <= stats_q.latency_cycle_sum +
            (waiting_q ? cycle_i - request_cycle_q : 64'd0);
      end

      if (bus_i.req_valid && !bus_i.req_ready)
        stats_q.request_stall_cycle_count <= stats_q.request_stall_cycle_count + 64'd1;
      if (bus_i.rsp_valid && !bus_i.rsp_ready)
        stats_q.response_stall_cycle_count <= stats_q.response_stall_cycle_count + 64'd1;

      // 计数使用更新前的旧请求时间戳。同拍接受新请求时，保留新事务；
      // 零周期响应已完成服务，只有响应背压才需要继续保留它。
      if (req_fire) begin
        request_cycle_q <= cycle_i;
        waiting_q <= !zero_cycle_response || !bus_i.rsp_ready;
        response_seen_q <= zero_cycle_response && !flush_i && !bus_i.rsp_ready;
      end else if (rsp_fire || flush_i) begin
        waiting_q <= 1'b0;
        response_seen_q <= 1'b0;
      end else if (sample_response) begin
        response_seen_q <= 1'b1;
      end
    end
  end

endmodule
`endif
