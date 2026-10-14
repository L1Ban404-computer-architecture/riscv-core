// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 单笔在途的关键字优先回填。请求接受后锁存地址，WRAP 从目标字开始，首拍
// 寄存后即可回应 CPU。响应和剩余回填独立完成，两者均结束才接受下一笔 miss。
// Array 不反压回填；CPU 反压只保持首拍响应，不影响后续 AXI R 接收。
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
    IDLE,
    SEND_AR,
    RECEIVE_R
  } state_t;
  state_t state_q;
  logic [AddrWidth-1:0] beat_addr_q;
  logic [BeatIndexW-1:0] beat_q;
  logic error_q;
  logic expected_last;
  logic beat_error;
  logic burst_done;

  initial begin
    RefillGeometry :
    assert (icache_is_power_of_two(
        BeatBytes
    ) && (DataWidth % 8 == 0) && (BlockBytes >= BeatBytes) && (BlockBytes % BeatBytes == 0) &&
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
  // 响应码、ID 或长度错误都使行无效。首拍上的错误同时报给 CPU；后续
  // 错误不改写首拍响应。提前 RLAST 或收满预期拍数均结束本次回填。
  // 这里只检测协议错误，不负责排空缺失 RLAST 后多发的 beat 或恢复总线。
  assign beat_error = (axi.r_payload.resp != AXI4_RESP_OKAY) ||
      (axi.r_payload.id != IdWidth'(AxiId)) ||
      (axi.r_payload.last != expected_last);
  assign burst_done = axi.r_payload.last || expected_last;

  assign axi.awvalid = 1'b0;
  assign axi.aw_payload = '0;
  assign axi.wvalid = 1'b0;
  assign axi.w_payload = '0;
  assign axi.bready = 1'b0;
  assign axi.arvalid = state_q == SEND_AR;
  // SEND_AR 中地址保持不变，进入 RECEIVE_R 后才随 beat 推进。
  assign axi.ar_payload.addr = beat_addr_q;
  assign axi.ar_payload.id = IdWidth'(AxiId);
  assign axi.ar_payload.len = 8'(WordCount - 1);
  assign axi.ar_payload.size = 3'($clog2(BeatBytes));
  assign axi.ar_payload.burst = (WordCount == 1) ? AXI4_BURST_INCR : AXI4_BURST_WRAP;
  assign axi.rready = state_q == RECEIVE_R;

  // 接受请求当拍通知 Array 分配并阻塞目标 line，此时还没有数据 beat。
  assign refill.valid = (state_q != IDLE) || miss.req_fire;
  assign refill.addr = (state_q == IDLE) ? miss.req_payload.addr : beat_addr_q;
  assign refill.beat_valid = axi.r_fire;
  assign refill.payload.data = axi.r_payload.data;
  assign refill.payload.last = refill.beat_valid && burst_done;
  assign refill.payload.error = error_q || (refill.beat_valid && beat_error);

  // 首拍只写一次。错误也在首拍锁存，后续故障只能使整行失效，不能改写响应。
  typedef struct packed {
    logic [DataWidth-1:0] rdata;
    logic error;
  } rsp_t;
  logic rsp_push;
  logic rsp_stream_ready;
  rsp_t rsp_push_payload;
  rsp_t rsp_payload;

  // 回填结束且首拍响应已消费，才能交出处理器的所有权。
  assign miss.req_ready = (state_q == IDLE) && !miss.rsp_valid;
  assign rsp_push = refill.beat_valid && (beat_q == '0);
  assign rsp_push_payload = '{rdata: beat_error ? '0 : axi.r_payload.data, error: beat_error};
  assign miss.rsp_payload.rdata = rsp_payload.rdata;
  assign miss.rsp_payload.error = rsp_payload.error;

  stream_register #(
      .T(rsp_t)
  ) u_rsp_word (
      .clk_i,
      .rst_ni,
      .flush_i(1'b0),
      .valid_i(rsp_push),
      .ready_o(rsp_stream_ready),
      .data_i (rsp_push_payload),
      .valid_o(miss.rsp_valid),
      .ready_i(miss.rsp_ready),
      .data_o (rsp_payload)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE;
      beat_addr_q <= '0;
      beat_q <= '0;
      error_q <= 1'b0;
    end else begin
      case (state_q)
        IDLE:
        if (miss.req_fire) begin
          state_q <= SEND_AR;
          beat_addr_q <= miss.req_payload.addr;
          beat_q <= '0;
          error_q <= 1'b0;
        end
        SEND_AR: if (axi.ar_fire) state_q <= RECEIVE_R;
        RECEIVE_R:
        if (axi.r_fire) begin
          error_q <= error_q || beat_error;
          if (burst_done) state_q <= IDLE;
          else begin
            beat_addr_q <= next_beat_addr(beat_addr_q);
            beat_q <= beat_q + BeatIndexW'(1);
          end
        end
        default: ;
      endcase
    end
  end

  logic unused_axi_write;
  assign unused_axi_write = ^{axi.awready, axi.aw_fire, axi.wready, axi.w_fire,
      axi.bvalid, axi.b_payload, axi.b_fire};

`ifndef SYNTHESIS
  ICacheMissRspStorageAvailable :
  assert property (@(posedge clk_i) disable iff (!rst_ni) (!rsp_push || rsp_stream_ready));
`endif
endmodule
