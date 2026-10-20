// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 记录当前请求并核对回应。flush 取消旧请求，同拍新请求继续参与比较。
// invalidate 上升沿切换内存镜像，已在途请求只检查归属，不比较数据。
module fv_scoreboard
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = ICacheAddrWidth,
  parameter int unsigned DataWidth = ICacheDataWidth,
  localparam int unsigned WordAddrW = AddrWidth - 2
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic invalidate_i,
  input logic [DataWidth-1:0] rsp_instr_i,

  core_bus_if.monitor core_bus,

  output logic [WordAddrW-1:0] rsp_word_addr_o
);

  logic [AddrWidth-1:0] scoreboard_addr_q;
  logic waiting_q;
  logic exempt_q;
  logic invalidate_q;
  logic invalidate_rise;

  assign rsp_word_addr_o = scoreboard_addr_q[AddrWidth-1:2];
  assign invalidate_rise = invalidate_i && !invalidate_q;

  initial begin
    scoreboard_addr_q = '0;
    waiting_q = 1'b0;
    exempt_q = 1'b0;
    invalidate_q = 1'b0;
    DataWidth32: assert (DataWidth == 32);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      scoreboard_addr_q <= '0;
      waiting_q <= 1'b0;
      exempt_q <= 1'b0;
      invalidate_q <= 1'b0;
    end else begin
      invalidate_q <= invalidate_i;

      if (core_bus.req_fire) begin
        scoreboard_addr_q <= core_bus.req_payload.addr;
        waiting_q <= 1'b1;
        exempt_q <= 1'b0;
      end else if (core_bus.rsp_fire || flush_i) begin
        waiting_q <= 1'b0;
        exempt_q <= 1'b0;
      end else if (invalidate_rise && waiting_q) begin
        exempt_q <= 1'b1;
      end
    end
  end

  // 有效回应必须属于未取消请求；除失效切换期间外，数据必须匹配。
  ResponseMatches:
  assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !core_bus.rsp_valid || (waiting_q && !flush_i &&
      (exempt_q || invalidate_rise ||
      (!core_bus.rsp_payload.error && core_bus.rsp_payload.rdata == rsp_instr_i)))));

endmodule
