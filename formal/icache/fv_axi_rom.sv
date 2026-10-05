// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单笔在途的 AXI 只读从设备。
// 接受 AR 后按 INCR 回 arlen+1 拍，每拍一个数据总线字，地址按字递增并在 4KB 边界回绕。
// 末拍 last 为 1，resp 为 OKAY，数据取 rdata_i。
// hold_ar_i 推迟接受 AR；hold_r_i 在拍间插入等待，已放上的 R 保持到握手。
// 写通道保持空闲。arsize 和 arburst 不参与译码。
module fv_axi_rom
  import riscv_bus_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = ICACHE_AXI_ID,
  localparam int unsigned WordAddrW = AddrWidth - 2,
  localparam int unsigned BeatBytes = DataWidth / 8
) (
  input logic clk_i,
  input logic rst_ni,
  input logic hold_ar_i,
  input logic hold_r_i,
  input logic [DataWidth-1:0] rdata_i,
  output logic [WordAddrW-1:0] word_addr_o,

  axi4_if.slave axi
);

  typedef enum logic [1:0] {
    FV_AXI_IDLE = 2'b00,
    FV_AXI_WAIT = 2'b01,
    FV_AXI_BEAT = 2'b10
  } fv_axi_state_e;

  fv_axi_state_e state_q;
  logic [AddrWidth-1:0] addr_q;
  logic [7:0] len_q;
  logic [7:0] beat_q;
  logic last_beat;

  if (AddrWidth > 12) begin : gen_next_beat
    function automatic logic [AddrWidth-1:0] step(input logic [AddrWidth-1:0] addr);
      return {addr[AddrWidth-1:12], addr[11:0] + 12'(BeatBytes)};
    endfunction
  end else begin : gen_next_beat
    function automatic logic [AddrWidth-1:0] step(input logic [AddrWidth-1:0] addr);
      return addr + AddrWidth'(BeatBytes);
    endfunction
  end

  assign word_addr_o = addr_q[AddrWidth-1:2];
  assign last_beat = beat_q == len_q;
  assign axi.arready = state_q == FV_AXI_IDLE && !hold_ar_i;
  assign axi.rvalid = state_q == FV_AXI_BEAT;
  assign axi.r_payload = '{
    resp: AXI4_RESP_OKAY,
    data: rdata_i,
    last: last_beat,
    id: IdWidth'(AxiId)
  };

  assign axi.awready = 1'b0;
  assign axi.wready = 1'b0;
  assign axi.bvalid = 1'b0;
  assign axi.b_payload = '{resp: AXI4_RESP_OKAY, id: '0};

  initial begin
    state_q = FV_AXI_IDLE;
    addr_q = '0;
    len_q = '0;
    beat_q = '0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= FV_AXI_IDLE;
      addr_q <= '0;
      len_q <= '0;
      beat_q <= '0;
    end else begin
      case (state_q)
        FV_AXI_IDLE: begin
          if (axi.ar_fire) begin
            addr_q <= axi.ar_payload.addr;
            len_q <= axi.ar_payload.len;
            beat_q <= '0;
            state_q <= FV_AXI_WAIT;
          end
        end
        FV_AXI_WAIT: begin
          if (!hold_r_i) state_q <= FV_AXI_BEAT;
        end
        FV_AXI_BEAT: begin
          if (axi.r_fire) begin
            if (last_beat) begin
              state_q <= FV_AXI_IDLE;
            end else begin
              addr_q <= gen_next_beat.step(addr_q);
              beat_q <= beat_q + 8'd1;
              if (hold_r_i) state_q <= FV_AXI_WAIT;
            end
          end
        end
        default: state_q <= FV_AXI_IDLE;
      endcase
    end
  end

  logic unused_request;
  assign unused_request = ^{
    axi.awvalid, axi.aw_payload, axi.wvalid, axi.w_payload, axi.bready,
    axi.ar_payload.id, axi.ar_payload.size, axi.ar_payload.burst
  };

endmodule
