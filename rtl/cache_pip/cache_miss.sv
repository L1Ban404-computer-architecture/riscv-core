// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 流水线 I-cache 的缺失处理器。
//
// miss 请求在整段事务期间保持，块地址和字索引都由该地址组合得到。块地址同时驱动
// AXI AR 和 refill 地址通道。AR 只用一次：`ar_sent_q` 在握手后拉高，避免保持中的
// 请求被重复发出。`beat_q` 从 0 数到行尾，等于字索引的拍写入 stream，等于行尾的
// 拍结束 burst。
//
// 短 burst 或末拍丢失时终止回填并带 error 返回，避免 lookup 一直被压住。失败的
// last 不带 commit，阵列不把该行标为有效。
//
// 匹配 word 可以早于末拍进入 stream，但 miss 响应要等到 line 写回提交的下一拍
// 才交给 miss 总线。这样 CPU 回应不会在 refill 仍占用阵列时释放 lookup。
`include "common/assertions.svh"

module cache_miss
  import riscv_bus_pkg::*;
  import icache_pip_pkg::*;
#(
  parameter int unsigned AddrWidth = ICachePipAddrWidth,
  parameter int unsigned DataWidth = ICachePipDataWidth,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = ICACHE_AXI_ID,
  parameter int unsigned BlockBytes = ICachePipBlockBytes,
  localparam int unsigned BeatBytes = DataWidth / 8,
  localparam int unsigned BlockOffsetW = $clog2(BlockBytes),
  localparam int unsigned WordCount = BlockBytes / BeatBytes,
  localparam int unsigned WordIndexW = (WordCount > 1) ? $clog2(WordCount) : 1
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 缺失事务、阵列回填与下级存储
  cache_miss_if.slave miss,
  cache_refill_if.master refill,
  axi4_if.master axi
);

  typedef logic [WordIndexW-1:0] word_index_t;

  ////////////////////
  // 地址拆分
  ////////////////////

  // 块地址对齐到缓存行。字索引只保留行内 word 编号，单 word 行没有偏移。
  function automatic word_index_t word_from_addr(input logic [AddrWidth-1:0] address);
    word_index_t result;

    result = '0;
    if (WordCount > 1) result = word_index_t'(address >> $clog2(BeatBytes));
    return result;
  endfunction

  logic [AddrWidth-1:0] block_addr;
  word_index_t word_index;
  assign block_addr = {miss.req_payload.addr[AddrWidth-1:BlockOffsetW], {BlockOffsetW{1'b0}}};
  assign word_index = word_from_addr(miss.req_payload.addr);

  ////////////////////
  // 在途状态
  ////////////////////

  // ar_sent_q：AR 已经握手，不能再发。line_written_q：末拍已经写入，下一拍才能回应。
  // beat_q 是已经接受的拍号，同时用来认出目标字和末拍。
  logic ar_sent_q;
  logic line_written_q;
  word_index_t beat_q;
  logic error_q;

  ////////////////////
  // 当前拍
  ////////////////////

  logic expected_last;
  logic beat_error;
  logic burst_terminate;
  logic word_match;

  assign expected_last = beat_q == word_index_t'(WordCount - 1);
  assign word_match = beat_q == word_index;
  // 只在 data_fire 时采样，因此不必再与 rvalid 相与。
  assign beat_error = (axi.r_payload.resp != AXI4_RESP_OKAY) ||
      (axi.r_payload.id != IdWidth'(AxiId)) || (axi.r_payload.last != expected_last);
  assign burst_terminate = axi.r_payload.last || expected_last;

  //////////////////////////
  // AXI 读与 refill
  //////////////////////////

  // AR 只握手一次。refill 地址保持到末拍；R 等 AR 完成后再接收，因此数据至少晚地址一拍。
  assign axi.awvalid = 1'b0;
  assign axi.aw_payload = '0;
  assign axi.wvalid = 1'b0;
  assign axi.w_payload = '0;
  assign axi.bready = 1'b0;

  assign axi.arvalid = miss.req_valid && !ar_sent_q;
  assign axi.ar_payload.addr = block_addr;
  assign axi.ar_payload.id = IdWidth'(AxiId);
  assign axi.ar_payload.len = 8'(WordCount - 1);
  assign axi.ar_payload.size = 3'($clog2(BeatBytes));
  assign axi.ar_payload.burst = AXI4_BURST_INCR;

  assign refill.addr_valid = miss.req_valid && !line_written_q;
  assign refill.addr_payload.addr = block_addr;

  // rready 不依赖 rvalid，避免从设备等 ready 才拉高 valid。
  assign axi.rready = ar_sent_q && !line_written_q && refill.data_ready;
  assign refill.data_valid = axi.rvalid && axi.rready;
  assign refill.data_payload.data = axi.r_payload.data;
  assign refill.data_payload.last = refill.data_valid && burst_terminate;
  assign refill.data_payload.commit = refill.data_payload.last && !error_q && !beat_error;

  ////////////////////
  // miss 响应
  ////////////////////

  // 目标拍写入数据。burst 结束时 stream 仍空，说明没数到目标字，写入零。
  // 错误留在 error_q，响应输出时再把数据清零。
  logic rsp_push;
  logic [DataWidth-1:0] rsp_push_data;
  logic rsp_stream_ready;
  logic rsp_word_valid;
  logic [DataWidth-1:0] rsp_word_data;

  assign rsp_push = refill.data_fire && (word_match || (burst_terminate && !rsp_word_valid));
  assign rsp_push_data = word_match ? axi.r_payload.data : '0;
  assign miss.rsp_valid = rsp_word_valid && line_written_q;
  assign miss.rsp_payload.rdata = miss.rsp_valid && !error_q ? rsp_word_data : '0;
  assign miss.rsp_payload.error = miss.rsp_valid && error_q;

  stream_register #(
    .T(logic [DataWidth-1:0])
  ) u_rsp_word (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .valid_i(rsp_push),
    .ready_o(rsp_stream_ready),
    .data_i(rsp_push_data),
    .valid_o(rsp_word_valid),
    .ready_i(miss.rsp_ready && line_written_q),
    .data_o(rsp_word_data)
  );

  ////////////////////
  // 状态更新
  ////////////////////

  // 响应握手当拍请求仍有效。本拍回到初态，下一拍才能接收下一笔 miss。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_sent_q <= 1'b0;
      line_written_q <= 1'b0;
      beat_q <= '0;
      error_q <= 1'b0;
    end else if (!miss.req_valid || miss.rsp_fire) begin
      ar_sent_q <= 1'b0;
      line_written_q <= 1'b0;
      beat_q <= '0;
      error_q <= 1'b0;
    end else begin
      if (axi.ar_fire) ar_sent_q <= 1'b1;
      if (refill.data_fire) begin
        error_q <= error_q || beat_error;
        if (burst_terminate) begin
          beat_q <= '0;
          line_written_q <= 1'b1;
        end else begin
          beat_q <= beat_q + word_index_t'(1);
        end
      end
    end
  end

  // 写通道和 refill 地址 ready 不参与这里的状态。综合会裁掉断言，因此单独读出 stream ready。
  logic unused_sideband;
  assign unused_sideband = ^{
    axi.awready,
    axi.aw_fire,
    axi.wready,
    axi.w_fire,
    axi.bvalid,
    axi.b_payload,
    axi.b_fire,
    refill.addr_ready,
    refill.addr_fire,
    rsp_stream_ready
  };

  ////////////////////
  // 协议与参数断言
  ////////////////////

  `ASSERT_INIT(CacheMissBlockBytesValid,
               icache_pip_is_power_of_two(BlockBytes) && (BlockBytes >= 4))
  `ASSERT_INIT(CacheMissDataWidthValid,
               icache_pip_is_power_of_two(DataWidth) && (DataWidth >= 8) &&
                   (BlockBytes >= BeatBytes) && (WordCount <= 256))
  `ASSERT_INIT(CacheMissAxiIdFits, (AxiId >> IdWidth) == 0)

  `ASSERT(CacheMissRspAfterRefill, miss.rsp_valid |-> !refill.addr_valid && !refill.data_valid,
          clk_i, !rst_ni, "Miss response must wait until the refill write has retired.")
  `ASSERT(CacheMissNeverWrites, !axi.awvalid && !axi.wvalid && !axi.bready, clk_i, !rst_ni,
          "ICache miss unit must not drive AXI write channels.")
  `ASSERT(CacheMissPushAccepted, rsp_push |-> rsp_stream_ready, clk_i, !rst_ni,
          "The response word must be accepted into the stream register.")
  `ASSERT_STABLE(CacheMissArStable, axi.arvalid, axi.arready, axi.ar_payload, '0, clk_i, !rst_ni,
                 "AXI AR must remain stable while stalled.")
  `ASSERT_STABLE(CacheMissRefillAddrStable, refill.addr_valid, refill.addr_ready,
                 refill.addr_payload, '0, clk_i, !rst_ni,
                 "Refill address must remain stable until the last data beat.")
  `ASSERT_STABLE(CacheMissRefillDataStable, refill.data_valid, refill.data_ready,
                 refill.data_payload, '0, clk_i, !rst_ni,
                 "Refill data must remain stable while backpressured.")
  `ASSERT_STABLE(CacheMissResponseStable, miss.rsp_valid, miss.rsp_ready, miss.rsp_payload, '0,
                 clk_i, !rst_ni, "Miss response must remain stable while backpressured.")

endmodule
