// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns / 1ps

// I-cache 专用 AXI4 只读存储模型。
//
// 一次只处理一笔 burst，返回数据由地址确定，便于不同 cache 几何共享期望值。
// 支持独立的 AR 反压、R 通道间歇及 RRESP、RID、RLAST 错误注入。
module icache_axi_memory_model
  import riscv_bus_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4
) (
  // 全局控制与 AXI4 从接口
  input logic clk_i,
  input logic rst_ni,
  axi4_if.slave axi,

  // 通道停顿与错误注入
  input logic ar_stall_i,
  input logic r_gap_i,
  input logic inject_r_error_i,
  input logic inject_wrong_id_i,
  // 0：正常；1：首拍提前 RLAST；2：期望末拍缺少 RLAST。
  input logic [1:0] last_mode_i,

  // 已完成握手的地址与数据拍计数
  output int unsigned ar_count_o,
  output int unsigned r_count_o
);

  //////////////////////
  // 只读事务锁存状态 //
  //////////////////////

  logic busy_q;
  logic [AddrWidth-1:0] base_addr_q;
  logic [IdWidth-1:0] id_q;
  logic [7:0] len_q;
  logic [7:0] beat_q;
  logic inject_r_error_q;
  logic inject_wrong_id_q;
  logic [1:0] last_mode_q;

  logic ar_fire;
  logic r_fire;
  logic model_last;
  logic model_terminal;

  // 使用地址直接生成稳定且可预测的数据，不需要额外的存储阵列。
  function automatic logic [DataWidth-1:0] memory_word(input logic [AddrWidth-1:0] address);
    return DataWidth'(32'hc001_0000 ^ 32'(address));
  endfunction

  assign ar_fire = axi.arvalid && axi.arready;
  assign r_fire = axi.rvalid && axi.rready;
  assign model_last = (last_mode_q == 2'd1) ? (beat_q == 0) :
      (last_mode_q == 2'd2) ? 1'b0 : (beat_q == len_q);
  // missing-RLAST 模式仍在规定拍数后结束模型事务，防止测试平台自身死锁。
  assign model_terminal = (last_mode_q == 2'd1) ? (beat_q == 0) : (beat_q == len_q);

  //////////////////////
  // AXI4 组合通道驱动 //
  //////////////////////

  always_comb begin
    // 模型只服务 I-cache，写通道永久关闭。
    axi.awready = 1'b0;
    axi.wready = 1'b0;
    axi.bvalid = 1'b0;
    axi.b_payload = '0;
    axi.arready = rst_ni && !busy_q && !ar_stall_i;
    axi.rvalid = rst_ni && busy_q && !r_gap_i;
    axi.r_payload.resp = (inject_r_error_q && (beat_q == 0)) ? 2'b10 : AXI4_RESP_OKAY;
    axi.r_payload.data = memory_word(base_addr_q + AddrWidth'(beat_q * 4));
    axi.r_payload.last = model_last;
    axi.r_payload.id = inject_wrong_id_q ? (id_q ^ IdWidth'(1)) : id_q;
  end

  ////////////////////////
  // 地址接收与逐拍返回 //
  ////////////////////////

  // 错误注入配置在 AR handshake 时锁存，确保整个 burst 期间保持一致。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q <= 1'b0;
      base_addr_q <= '0;
      id_q <= '0;
      len_q <= '0;
      beat_q <= '0;
      inject_r_error_q <= 1'b0;
      inject_wrong_id_q <= 1'b0;
      last_mode_q <= '0;
      ar_count_o <= 0;
      r_count_o <= 0;
    end else begin
      if (ar_fire) begin
        busy_q <= 1'b1;
        base_addr_q <= axi.ar_payload.addr;
        id_q <= axi.ar_payload.id;
        len_q <= axi.ar_payload.len;
        beat_q <= '0;
        inject_r_error_q <= inject_r_error_i;
        inject_wrong_id_q <= inject_wrong_id_i;
        last_mode_q <= last_mode_i;
        ar_count_o <= ar_count_o + 1;
      end
      if (r_fire) begin
        r_count_o <= r_count_o + 1;
        if (model_terminal) begin
          busy_q <= 1'b0;
          beat_q <= '0;
        end else begin
          beat_q <= beat_q + 8'd1;
        end
      end
    end
  end

endmodule
