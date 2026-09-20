// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

// 超小型 I-cache 内部语义接口。
//
// 封装控制器与阵列之间的一拍查询和 refill 写通路。
// 不额外引入队列、skid buffer 或完整缓存行缓冲。

//////////////////
// 阵列查询事务 //
//////////////////

// req_valid 当拍启动 tag/data SRAM 读，没有 ready 握手。下一拍 rsp_payload
// 对应该次地址：hit、命中数据和当前牺牲路。控制器只在 Lookup 状态采样结果。commit 仅在命中
// 请求与 CoreBus 响应同拍完成时置位，用于更新替换状态；反压期间不得更新状态。
interface icache_lookup_if
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned WayCount = ICacheWayCount,
  localparam int unsigned WayIndexW = (WayCount > 1) ? $clog2(WayCount) : 1
);
  typedef struct packed {logic [AddrWidth-1:0] addr;} req_payload_t;
  typedef struct packed {
    logic hit;
    logic [DataWidth-1:0] rdata;
    logic [WayIndexW-1:0] victim_way;
  } rsp_payload_t;

  logic req_valid;
  req_payload_t req_payload;
  rsp_payload_t rsp_payload;
  logic commit;

  modport controller(output req_valid, req_payload, commit, input rsp_payload);
  modport array(input req_valid, req_payload, commit, output rsp_payload);
  modport monitor(input req_valid, req_payload, rsp_payload, commit);
endinterface

//////////////////
// 缓存行回填事务 //
//////////////////

// begin 在 AXI AR 握手时占用牺牲路并写入新 tag；beat 对应每次 AXI R 握手，数据
// 直接写入目标 word。最后一拍仅在整个 burst 无错误时携带 commit，使目标行生效。
// miss 完成后的 CoreBus 响应由控制器旁路目标 beat，不再从阵列读回。
interface icache_refill_if
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned BlockBytes = ICacheBlockBytes,
  parameter int unsigned SetCount = ICacheSetCount,
  parameter int unsigned WayCount = ICacheWayCount,
  localparam int unsigned SetIndexW = (SetCount > 1) ? $clog2(SetCount) : 1,
  localparam int unsigned WordCount = BlockBytes / (DataWidth / 8),
  localparam int unsigned WordIndexW = (WordCount > 1) ? $clog2(WordCount) : 1,
  localparam int unsigned WayIndexW = (WayCount > 1) ? $clog2(WayCount) : 1
);
  typedef struct packed {
    logic [AddrWidth-1:0] addr;
    logic [WayIndexW-1:0] way;
  } begin_payload_t;
  typedef struct packed {
    logic [SetIndexW-1:0] set;
    logic [WayIndexW-1:0] way;
    logic [WordIndexW-1:0] word;
    logic [DataWidth-1:0] data;
    logic commit;
  } beat_payload_t;

  logic begin_valid;
  begin_payload_t begin_payload;
  logic beat_valid;
  beat_payload_t beat_payload;

  modport controller(output begin_valid, begin_payload, beat_valid, beat_payload);
  modport array(input begin_valid, begin_payload, beat_valid, beat_payload);
  modport monitor(input begin_valid, begin_payload, beat_valid, beat_payload);
endinterface

`ifndef SYNTHESIS
// 实时 I-cache 性能计数快照。计数器只供仿真分析，不参与功能控制。
interface icache_performance_debug_if;
  icache_pkg::icache_performance_payload_t payload;
  modport producer(output payload);
  modport consumer(input payload);
  modport monitor(input payload);
endinterface
`endif

/* verilator lint_on DECLFILENAME */
