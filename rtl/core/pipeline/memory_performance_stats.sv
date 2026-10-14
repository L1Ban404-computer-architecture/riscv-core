// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 按 CoreBus 握手统计事务和背压。取指 flush 视作旧事务结束，数据侧接 0。
// 仿真端由两侧累计周期和计算延迟，不修正未完成请求。
`ifndef SYNTHESIS
module memory_performance_stats
  import riscv_core_pkg::*;
(
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic [63:0] cycle_i,
  core_bus_if.monitor bus,
  output memory_performance_payload_t stats_o
);
  memory_performance_payload_t stats_q;
  logic waiting_q;

  assign stats_o = stats_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stats_q <= '0;
      waiting_q <= 1'b0;
    end else begin
      if (bus.req_fire) begin
        waiting_q <= 1'b1;
        stats_q.transaction_count <= stats_q.transaction_count + 64'd1;
        stats_q.request_cycle_sum <= stats_q.request_cycle_sum + 128'(cycle_i);
      end else if (bus.rsp_fire || flush_i) begin
        waiting_q <= 1'b0;
      end

      if (bus.rsp_fire || (flush_i && waiting_q)) begin
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
