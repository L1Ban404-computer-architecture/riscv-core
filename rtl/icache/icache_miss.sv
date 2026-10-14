// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单笔 miss 按 WRAP 从目标字开始回填，首拍缓存后即可回应。
// 回应与回填独立完成，两者都结束后才接受下一笔请求。
module icache_miss
  import riscv_bus_pkg::*;
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = ICacheAddrWidth,
  parameter int unsigned DataWidth = ICacheDataWidth,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = ICACHE_AXI_ID,
  parameter int unsigned BlockBytes = ICacheBlockBytes,
  localparam int unsigned BeatBytes = DataWidth / 8,
  localparam int unsigned WordCount = BlockBytes / BeatBytes,
  localparam int unsigned BeatIndexW = (WordCount > 1) ? $clog2(WordCount) : 1
) (
  input logic clk_i,
  input logic rst_ni,
  icache_miss_if.slave miss,
  icache_refill_if.master refill,
  axi4_if.master axi
);

  typedef enum logic [1:0] {
    StateIdle,
    StateSendAr,
    StateReceiveR
  } state_e;
  typedef struct packed {
    logic [DataWidth-1:0] rdata;
    logic error;
  } rsp_t;

  state_e state_q;
  logic [AddrWidth-1:0] beat_addr_q;
  logic [BeatIndexW-1:0] beat_q;
  logic error_q;
  logic expected_last;
  logic beat_error;
  logic burst_done;
  logic rsp_push;
  logic rsp_stream_ready;
  rsp_t rsp_push_payload;
  logic unused_axi_write;

  initial begin
    RefillGeometry:
    assert (icache_is_power_of_two(BeatBytes) && (DataWidth % 8 == 0) &&
        (BlockBytes >= BeatBytes) && (BlockBytes % BeatBytes == 0) &&
        ((WordCount == 1) || (WordCount == 2) || (WordCount == 4) || (WordCount == 8) ||
         (WordCount == 16)))
    else $fatal(1, "I-cache requires 1/2/4/8/16 words per line");
  end

  // 只有低 line offset 位递增；高位在整次事务内保持不变。
  function automatic logic [AddrWidth-1:0] next_beat_addr(input logic [AddrWidth-1:0] addr);
    return (addr & ~AddrWidth'(BlockBytes - 1)) |
        ((addr + AddrWidth'(BeatBytes)) & AddrWidth'(BlockBytes - 1));
  endfunction

  assign expected_last = beat_q == BeatIndexW'(WordCount - 1);
  // 提前 RLAST 或收满预期拍数即结束；协议错误使整行无效，不恢复违规总线。
  assign beat_error = (axi.r_payload.resp != AXI4_RESP_OKAY) ||
      (axi.r_payload.id != IdWidth'(AxiId)) ||
      (axi.r_payload.last != expected_last);
  assign burst_done = axi.r_payload.last || expected_last;

  assign miss.req_ready = (state_q == StateIdle) && !miss.rsp_valid;

  // 只读 AXI 事务。AR 被接受后，地址随回填 beat 在 line 内回绕。
  assign axi.awvalid = 1'b0;
  assign axi.aw_payload = '0;
  assign axi.wvalid = 1'b0;
  assign axi.w_payload = '0;
  assign axi.bready = 1'b0;
  assign axi.arvalid = state_q == StateSendAr;
  assign axi.ar_payload = '{
    addr: beat_addr_q,
    id: IdWidth'(AxiId),
    len: 8'(WordCount - 1),
    size: 3'($clog2(BeatBytes)),
    burst: (WordCount == 1) ? AXI4_BURST_INCR : AXI4_BURST_WRAP
  };
  assign axi.rready = state_q == StateReceiveR;

  // 接受请求当拍通知 Array 分配并阻塞目标 line，此时还没有数据 beat。
  assign refill.valid = (state_q != StateIdle) || miss.req_fire;
  assign refill.addr = (state_q == StateIdle) ? miss.req_payload.addr : beat_addr_q;
  assign refill.beat_valid = axi.r_fire;
  assign refill.payload = '{
    data: axi.r_payload.data,
    last: refill.beat_valid && burst_done,
    error: error_q || (refill.beat_valid && beat_error)
  };

  // 仅首拍数据和错误交给 CPU，后续 beat 的错误不能改写已缓存回应。
  assign rsp_push = refill.beat_valid && (beat_q == '0);
  assign rsp_push_payload = '{rdata: beat_error ? '0 : axi.r_payload.data, error: beat_error};

  stream_register #(
    .T(rsp_t)
  ) u_rsp_word (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .valid_i(rsp_push),
    .ready_o(rsp_stream_ready),
    .data_i(rsp_push_payload),
    .valid_o(miss.rsp_valid),
    .ready_i(miss.rsp_ready),
    .data_o(miss.rsp_payload)
  );

  // 请求 → AR → R；首拍回应与背景回填的寿命分别管理。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StateIdle;
      beat_addr_q <= '0;
      beat_q <= '0;
      error_q <= 1'b0;
    end else begin
      case (state_q)
        StateIdle: begin
          if (miss.req_fire) begin
            state_q <= StateSendAr;
            beat_addr_q <= miss.req_payload.addr;
            beat_q <= '0;
            error_q <= 1'b0;
          end
        end
        StateSendAr: begin
          if (axi.ar_fire) state_q <= StateReceiveR;
        end
        StateReceiveR: begin
          if (axi.r_fire) begin
            error_q <= error_q || beat_error;
            if (burst_done) state_q <= StateIdle;
            else begin
              beat_addr_q <= next_beat_addr(beat_addr_q);
              beat_q <= beat_q + BeatIndexW'(1);
            end
          end
        end
        default: ;
      endcase
    end
  end

  assign unused_axi_write = ^{axi.awready, axi.aw_fire, axi.wready, axi.w_fire,
      axi.bvalid, axi.b_payload, axi.b_fire};

`ifndef SYNTHESIS
  ICacheMissRspStorageAvailable:
  assert property (@(posedge clk_i) disable iff (!rst_ni) (!rsp_push || rsp_stream_ready));
`endif
endmodule
