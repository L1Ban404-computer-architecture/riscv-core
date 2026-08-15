// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// CoreBus 顺序计分板。
//
// 在请求握手时记录预期结果，并按请求顺序检查实际 CoreBus 响应。
// 预期值必须与请求同拍提供；响应不得超前、缺失或越序；队列溢出立即终止测试。
module cache_corebus_scoreboard
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
#(
  parameter int unsigned Depth = 2048,
  parameter int unsigned CountW = (Depth > 1) ? $clog2(Depth + 1) : 1
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 被监视事务与预期结果
  core_bus_if.monitor core_bus,
  input word_t expected_rdata_i,
  input logic expected_error_i,

  // 队列状态
  output logic empty_o,
  output logic [CountW-1:0] pending_o
);

  ////////////////////////////
  // 预期结果队列与握手事件 //
  ////////////////////////////

  word_t expected_rdata_q[Depth];
  logic expected_error_q[Depth];
  int unsigned head_q;
  int unsigned tail_q;
  logic request_fire;
  logic response_fire;

  assign request_fire = core_bus.req_valid && core_bus.req_ready;
  assign response_fire = core_bus.rsp_valid && core_bus.rsp_ready;
  assign empty_o = pending_o == '0;

  ////////////////////////
  // 请求记录与响应检查 //
  ////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q <= 0;
      tail_q <= 0;
      pending_o <= '0;
    end else begin
      if (request_fire) begin
        if (tail_q >= Depth) $fatal(1, "Test scoreboard overflow.");
        expected_rdata_q[tail_q] <= expected_rdata_i;
        expected_error_q[tail_q] <= expected_error_i;
        tail_q <= tail_q + 1;
      end

      if (response_fire) begin
        if (pending_o == '0) $fatal(1, "Unexpected CoreBus response.");
        if (core_bus.error !== expected_error_q[head_q]) begin
          $fatal(1, "CoreBus error mismatch at response %0d.", head_q);
        end
        if (!core_bus.error &&
            (core_bus.rdata !== expected_rdata_q[head_q])) begin
          $fatal(1,
                 "CoreBus data mismatch at response %0d: expected %08x, got %08x.",
                 head_q, expected_rdata_q[head_q], core_bus.rdata);
        end
        head_q <= head_q + 1;
      end

      unique case ({request_fire, response_fire})
        2'b10: pending_o <= pending_o + CountW'(1);
        2'b01: pending_o <= pending_o - CountW'(1);
        default: ;
      endcase
    end
  end

endmodule
