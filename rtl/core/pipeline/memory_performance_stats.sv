// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// CoreBus 事件统计，只观察握手，不驱动事务通路。
// 事务数按请求握手累计，两侧独立累计握手时刻和背压周期。
// 仿真端计算累计时刻之差 / 事务数，不修正未完成请求。
`ifndef SYNTHESIS
module memory_performance_stats
  import riscv_core_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  input logic [63:0] cycle_i,
  core_bus_if.monitor bus,
  output memory_performance_payload_t stats_o
);
  logic request_fire, response_fire;
  memory_performance_payload_t stats_q;

  assign stats_o = stats_q;
  assign request_fire = bus.req_valid && bus.req_ready;
  assign response_fire = bus.rsp_valid && bus.rsp_ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stats_q <= '0;
    end else begin
      if (request_fire) begin
        stats_q.transaction_count <= stats_q.transaction_count + 64'd1;
        stats_q.request_cycle_sum <= stats_q.request_cycle_sum + 128'(cycle_i);
      end
      if (response_fire) begin
        stats_q.response_cycle_sum <= stats_q.response_cycle_sum + 128'(cycle_i);
      end
      if (bus.req_valid && !bus.req_ready)
        stats_q.request_stall_cycle_count <= stats_q.request_stall_cycle_count + 64'd1;
      if (bus.rsp_valid && !bus.rsp_ready)
        stats_q.response_stall_cycle_count <= stats_q.response_stall_cycle_count + 64'd1;
    end
  end

endmodule
`endif
