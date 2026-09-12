// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "common/assertions.svh"

// CoreBus 单请求在途的事件统计，只观察握手，不驱动事务通路。
// 请求侧与响应侧独立累计数量和握手时刻；没有配对队列或事务状态机。
// 仿真端用响应时刻之和减请求时刻之和，并排除最后一个未完成请求。
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
        stats_q.request_count <= stats_q.request_count + 64'd1;
        stats_q.request_cycle_sum <= stats_q.request_cycle_sum + cycle_i;
        stats_q.last_request_cycle <= cycle_i;
      end
      if (response_fire) begin
        stats_q.completion_count <= stats_q.completion_count + 64'd1;
        stats_q.response_cycle_sum <= stats_q.response_cycle_sum + cycle_i;
      end
      if (bus.req_valid && !bus.req_ready)
        stats_q.request_stall_cycle_count <= stats_q.request_stall_cycle_count + 64'd1;
    end
  end

  // 只在断言中关联两个事件流；不产生功能通路的限流或控制信号。
  // verilog_format: off
  `ASSERT(MemoryPerfResponseOwned,
    response_fire |-> (stats_q.request_count != stats_q.completion_count || request_fire),
    clk_i, !rst_ni, "Performance response must match an accepted request.")
  `ASSERT(MemoryPerfSingleOutstanding,
    (stats_q.request_count + 64'(request_fire) -
     stats_q.completion_count - 64'(response_fire)) <= 64'd1,
    clk_i, !rst_ni, "Performance monitor supports only one outstanding request.")
  // verilog_format: on
endmodule
