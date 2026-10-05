// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// AXI4 读突发拆分器。
//
// 临时适配只支持单拍读请求的外部 AXI 从设备：接收一笔 I-cache 突发读，
// 按 beat 顺序发出多个 ARLEN=0 的递增读请求，R 数据不经过额外缓冲直接返回。
// 任意时刻仅允许一个子请求在途，不实现写通道或多 outstanding 队列。
`include "common/assertions.svh"

module axi4_burst_splitter
  import riscv_bus_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 上游突发 AXI 与下游单拍 AXI
  axi4_if.slave burst_axi,
  axi4_if.master single_axi
);

  //////////////////////////
  // 最小突发事务上下文 //
  //////////////////////////

  logic busy_q;
  logic waiting_r_q;
  logic [AddrWidth-1:0] base_addr_q;
  logic [IdWidth-1:0] burst_id_q;
  logic [7:0] burst_len_q;
  logic [2:0] burst_size_q;
  logic [7:0] beat_index_q;

  logic final_beat;
  logic downstream_r_error;

  assign final_beat = beat_index_q == burst_len_q;
  // 每个下游请求都是单拍，缺失 RLAST 在任意 beat 都应报告为协议错误；
  // 拆分器仍按原突发长度推进，避免错误响应把上游控制器永久挂起。
  assign downstream_r_error = (single_axi.r_payload.resp != AXI4_RESP_OKAY) ||
      !single_axi.r_payload.last;

  //////////////////////////
  // AXI 通道组合适配逻辑 //
  //////////////////////////

  always_comb begin
    // 上游 I-cache 只读；写通道保持关闭。
    burst_axi.awready = 1'b0;
    burst_axi.wready = 1'b0;
    burst_axi.bvalid = 1'b0;
    burst_axi.b_payload = '0;
    burst_axi.arready = !busy_q && single_axi.arready;
    burst_axi.rvalid = waiting_r_q && single_axi.rvalid;
    burst_axi.r_payload = '0;
    if (waiting_r_q) begin
      burst_axi.r_payload.resp = downstream_r_error ? 2'b10 : single_axi.r_payload.resp;
      burst_axi.r_payload.data = single_axi.r_payload.data;
      burst_axi.r_payload.last = final_beat;
      burst_axi.r_payload.id = single_axi.r_payload.id;
    end

    single_axi.awvalid = 1'b0;
    single_axi.aw_payload = '0;
    single_axi.wvalid = 1'b0;
    single_axi.w_payload = '0;
    single_axi.bready = 1'b0;
    single_axi.arvalid = (!busy_q && burst_axi.arvalid) ||
        (busy_q && !waiting_r_q);
    single_axi.ar_payload = '0;
    if (!busy_q) begin
      // 空闲时直接展示上游首个子请求，避免引入请求寄存器。
      single_axi.ar_payload = burst_axi.ar_payload;
      single_axi.ar_payload.len = 8'd0;
      single_axi.ar_payload.burst = AXI4_BURST_INCR;
    end else if (!waiting_r_q) begin
      // 后续 beat 只需保存首地址和最小 AXI 属性。
      single_axi.ar_payload.addr = base_addr_q +
          (AddrWidth'({1'b0, beat_index_q}) << burst_size_q);
      single_axi.ar_payload.id = burst_id_q;
      single_axi.ar_payload.len = 8'd0;
      single_axi.ar_payload.size = burst_size_q;
      single_axi.ar_payload.burst = AXI4_BURST_INCR;
    end
    single_axi.rready = waiting_r_q && burst_axi.rready;
  end

  //////////////////////////
  // 突发状态与 beat 计数 //
  //////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q <= 1'b0;
      waiting_r_q <= 1'b0;
      base_addr_q <= '0;
      burst_id_q <= '0;
      burst_len_q <= '0;
      burst_size_q <= '0;
      beat_index_q <= '0;
    end else begin
      if (single_axi.ar_fire) begin
        if (!busy_q) begin
          base_addr_q <= burst_axi.ar_payload.addr;
          burst_id_q <= burst_axi.ar_payload.id;
          burst_len_q <= burst_axi.ar_payload.len;
          burst_size_q <= burst_axi.ar_payload.size;
          beat_index_q <= '0;
        end
        busy_q <= 1'b1;
        waiting_r_q <= 1'b1;
      end else if (single_axi.r_fire) begin
        if (final_beat) begin
          busy_q <= 1'b0;
          waiting_r_q <= 1'b0;
          beat_index_q <= '0;
        end else begin
          waiting_r_q <= 1'b0;
          beat_index_q <= beat_index_q + 8'd1;
        end
      end
    end
  end

  //////////////
  // 协议检查 //
  //////////////

  `CHECK(AxiBurstSplitterNoWrites, !burst_axi.awvalid && !burst_axi.wvalid && !burst_axi.bready &&
      !single_axi.awvalid && !single_axi.wvalid && !single_axi.bready)
  `CHECK(AxiBurstSplitterSingleBeat, !single_axi.arvalid || (single_axi.ar_payload.len == 8'd0))
  `CHECK(AxiBurstSplitterNoReadOverlap, !waiting_r_q || !single_axi.arvalid)

endmodule
