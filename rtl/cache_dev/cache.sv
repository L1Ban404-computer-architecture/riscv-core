// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 参数化通用 Cache 顶层。
//
// 连接顺序控制面、组相联阵列和 AXI4 写回/回填引擎，对外提供稳定的
// CoreBus 从接口与 AXI4 主接口。
// 容量几何均为二次幂；缓存行必须包含整数个 AXI beat；未完成事务容量必须
// 覆盖查询流水延迟；只读配置禁止接收 store 或发起写回。
`include "common/assertions.svh"

module cache
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
  import cache_pkg::*;
#(
  parameter int unsigned AddrWidth = XLen,
  parameter int unsigned DataWidth = XLen,
  parameter int unsigned IdWidth = 4,
  parameter bit ReadOnly = CacheDefaultReadOnly,
  parameter int unsigned BlockBytes = CacheDefaultBlockBytes,
  parameter int unsigned SetCount = CacheDefaultSetCount,
  parameter int unsigned WayCount = CacheDefaultWayCount,
  parameter int unsigned LookupLatency = CacheDefaultLookupLatency,
  parameter int unsigned MaxOutstanding = CacheDefaultMaxOutstanding,
  parameter int unsigned AxiId = DCACHE_AXI_ID,
  localparam int unsigned BlockOffsetW = $clog2(BlockBytes),
  localparam int unsigned BlockAddrW = XLen - BlockOffsetW,
  localparam int unsigned SetIndexBits = $clog2(SetCount),
  localparam int unsigned SetIndexW = (SetCount > 1) ? SetIndexBits : 1,
  localparam int unsigned TagW = BlockAddrW - SetIndexBits,
  localparam int unsigned WordCount = BlockBytes / StrbW,
  localparam int unsigned WordIndexBits = $clog2(WordCount),
  localparam int unsigned WordIndexW = (WordCount > 1) ? WordIndexBits : 1,
  localparam int unsigned WayIndexW = (WayCount > 1) ? $clog2(WayCount) : 1,
  localparam int unsigned TxnIdW =
      (MaxOutstanding > 1) ? $clog2(MaxOutstanding) : 1,
  localparam int unsigned LineBits = BlockBytes * ByteW,
  localparam int unsigned LineBeats = BlockBytes / StrbW
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // CoreBus 与 AXI4
  core_bus_if.slave core_bus,
  axi4_if.master axi
);

  //////////////////
  // 内部语义接口 //
  //////////////////

  cache_lookup_req_if #(
    .AddrWidth(AddrWidth), .DataWidth(DataWidth), .BlockBytes(BlockBytes),
    .SetCount(SetCount), .MaxOutstanding(MaxOutstanding)
  ) lookup_req();
  cache_lookup_rsp_if #(
    .AddrWidth(AddrWidth), .DataWidth(DataWidth), .BlockBytes(BlockBytes),
    .SetCount(SetCount), .WayCount(WayCount),
    .MaxOutstanding(MaxOutstanding)
  ) lookup_rsp();
  cache_victim_req_if #(
    .SetCount(SetCount), .WayCount(WayCount)
  ) victim_req();
  cache_victim_rsp_if #(.BlockBytes(BlockBytes)) victim_rsp();
  cache_word_write_if #(
    .DataWidth(DataWidth), .BlockBytes(BlockBytes),
    .SetCount(SetCount), .WayCount(WayCount)
  ) word_write();
  cache_line_install_if #(
    .AddrWidth(AddrWidth), .BlockBytes(BlockBytes),
    .SetCount(SetCount), .WayCount(WayCount)
  ) line_install();
  cache_replacement_update_if #(
    .SetCount(SetCount), .WayCount(WayCount)
  ) replacement_update();
  cache_refill_req_if #(
    .AddrWidth(AddrWidth), .BlockBytes(BlockBytes)
  ) refill_req();
  cache_refill_rsp_if #(.BlockBytes(BlockBytes)) refill_rsp();

  ////////////////////////////
  // 控制面、阵列与回填引擎 //
  ////////////////////////////

  cache_control #(
    .ReadOnly(ReadOnly),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .MaxOutstanding(MaxOutstanding)
  ) u_cache_control (
    .clk_i,
    .rst_ni,
    .core_bus,
    .lookup_req,
    .lookup_rsp,
    .victim_req,
    .victim_rsp,
    .word_write,
    .line_install,
    .replacement_update,
    .refill_req,
    .refill_rsp
  );

  cache_array #(
    .ReadOnly(ReadOnly),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .LookupLatency(LookupLatency),
    .MaxOutstanding(MaxOutstanding)
  ) u_cache_array (
    .clk_i,
    .rst_ni,
    .lookup_req,
    .lookup_rsp,
    .victim_req,
    .victim_rsp,
    .word_write,
    .line_install,
    .replacement_update
  );

  cache_refill_engine #(
    .ReadOnly(ReadOnly),
    .BlockBytes(BlockBytes),
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .IdWidth(IdWidth),
    .AxiId(AxiId)
  ) u_cache_refill_engine (
    .clk_i,
    .rst_ni,
    .refill_req,
    .refill_rsp,
    .axi
  );

  ////////////////////
  // 参数与配置断言 //
  ////////////////////

  `ASSERT_INIT(CacheBlockBytesValid,
               (BlockBytes >= StrbW) && cache_is_power_of_two(BlockBytes),
               "Cache line size must be a power of two and at least one AXI beat.")
  `ASSERT_INIT(CacheBlockBeatAligned, (BlockBytes % StrbW) == 0,
               "Cache line size must contain an integer number of AXI beats.")
  `ASSERT_INIT(CacheLineBeatCountValid, (LineBeats > 0) && (LineBeats <= 256),
               "An AXI4 burst may contain between one and 256 beats.")
  `ASSERT_INIT(CacheSetCountValid,
               cache_is_power_of_two(SetCount),
               "Cache set count must be a power of two.")
  `ASSERT_INIT(CacheWayCountValid,
               cache_is_power_of_two(WayCount),
               "Cache way count must be a power of two.")
  `ASSERT_INIT(CacheLookupLatencyValid, LookupLatency > 0,
               "Cache lookup latency must be greater than zero.")
  `ASSERT_INIT(CacheOutstandingDepthValid,
               (MaxOutstanding > 0) && (MaxOutstanding >= LookupLatency),
               "Outstanding capacity must cover the complete lookup pipeline.")
  `ASSERT_INIT(CacheBlockAddressWidthValid, BlockOffsetW < XLen,
               "Cache line size must be smaller than the CPU address space.")
  `ASSERT_INIT(CacheTagWidthValid, (SetIndexBits < BlockAddrW) && (TagW > 0),
               "Cache address decomposition must leave at least one tag bit.")
  `ASSERT_INIT(CacheWordIndexWidthValid, WordIndexBits <= BlockOffsetW,
               "The word index must fit inside the cache-line offset.")

  if (ReadOnly) begin : gen_read_only_assertions
    `ASSERT(CacheReadOnlyRequest,
            core_bus.req_valid |-> !core_bus.req_payload.write,
            clk_i, !rst_ni, "A read-only cache must never receive a write request.")
  end

  `ASSERT_INIT(CacheAddressWidthSupported, AddrWidth == XLen)
  `ASSERT_INIT(CacheDataWidthSupported, DataWidth == XLen)
  `ASSERT_INIT(CacheAddressAndIdWidthsValid,
               AddrWidth > 0 && IdWidth > 0)
  `ASSERT_INIT(CacheDataWidthValid,
               DataWidth >= 8 && (DataWidth % 8) == 0 &&
                   (DataWidth & (DataWidth - 1)) == 0)
  `ASSERT_INIT(CacheAxiIdFits, (AxiId >> IdWidth) == 0)
  `ASSERT_INIT(CacheCoreBusAddrWidth,
               $bits(core_bus.req_payload.addr) == AddrWidth)
  `ASSERT_INIT(CacheCoreBusDataWidth,
               $bits(core_bus.req_payload.wdata) == DataWidth)
  `ASSERT_INIT(CacheAxiIdWidth, $bits(axi.aw_payload.id) == IdWidth)

endmodule
