// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 记下最近一次被接受的取指地址，以及这笔请求是否免比较。比较使用时钟沿之前的状态。
// 新请求要比较。invalidate 上升沿时已经在等的请求免比较，包括上升沿当拍的回应。
// 免比较的响应不限数据。其余响应没有错误，且数据等于 rsp_instr_i。
module fv_scoreboard
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = ICacheAddrWidth,
  parameter int unsigned DataWidth = ICacheDataWidth,
  localparam int unsigned WordAddrW = AddrWidth - 2
) (
  input logic clk_i,
  input logic rst_ni,
  input logic invalidate_i,
  input logic [DataWidth-1:0] rsp_instr_i,

  core_bus_if.monitor core_bus,
  icache_performance_debug_if.monitor performance,

  output logic [WordAddrW-1:0] rsp_word_addr_o
);

  logic [AddrWidth-1:0] scoreboard_addr_q;
  logic waiting_q;
  logic exempt_q;
  logic invalidate_q;
  logic invalidate_rise;
  logic rsp_exempt;
  logic [1:0] req_fire_q;

  assign rsp_word_addr_o = scoreboard_addr_q[AddrWidth-1:2];
  assign invalidate_rise = invalidate_i && !invalidate_q;
  assign rsp_exempt = waiting_q && (exempt_q || invalidate_rise);

  initial begin
    scoreboard_addr_q = '0;
    waiting_q = 1'b0;
    exempt_q = 1'b0;
    invalidate_q = 1'b0;
    req_fire_q = '0;
    DataWidth32: assert (DataWidth == 32);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      scoreboard_addr_q <= '0;
      waiting_q <= 1'b0;
      exempt_q <= 1'b0;
      invalidate_q <= 1'b0;
      req_fire_q <= '0;
    end else begin
      invalidate_q <= invalidate_i;
      req_fire_q <= {req_fire_q[0], core_bus.req_fire};

      if (core_bus.req_fire) scoreboard_addr_q <= core_bus.req_payload.addr;

      if (core_bus.req_fire) waiting_q <= 1'b1;
      else if (core_bus.rsp_fire) waiting_q <= 1'b0;

      if (core_bus.req_fire) exempt_q <= 1'b0;
      else if (core_bus.rsp_fire) exempt_q <= 1'b0;
      else if (invalidate_rise && waiting_q) exempt_q <= 1'b1;
    end
  end

  ResponseMatches:
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      !core_bus.rsp_fire || rsp_exempt ||
      (!core_bus.rsp_payload.error && core_bus.rsp_payload.rdata == rsp_instr_i));

  // 缺失 3 次。请求在接受的下一拍入账。
  ThreeMisses:
  cover property (@(posedge clk_i)
      performance.payload.request_count - performance.payload.hit_count == 64'd3);

  // 连续 3 拍完成请求握手。
  ConsecutiveReq:
  cover property (@(posedge clk_i) core_bus.req_fire && req_fire_q == 2'b11);

endmodule
