// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

// 超小型 I-cache 内部语义接口。
//
// 仅封装控制器与寄存器阵列之间的组合查询和 refill 数据通路，不额外引入队列、
// skid buffer 或流水寄存器。

//////////////////
// 组合查询事务 //
//////////////////

// req_valid 有效时，阵列组合返回 hit、命中数据和当前牺牲路，没有 ready 握手。
// commit 仅在命中请求与 CoreBus 响应同拍完成时置位，用于更新替换状态；反压期间
// 不得更新状态。
interface icache_lookup_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned WayCount = 2,
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
// read 是 miss 完成后的组合读回端口，用于返回原请求所需的 word。
interface icache_refill_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned BlockBytes = 4,
  parameter int unsigned SetCount = 2,
  parameter int unsigned WayCount = 2,
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
  typedef struct packed {
    logic [SetIndexW-1:0] set;
    logic [WayIndexW-1:0] way;
    logic [WordIndexW-1:0] word;
  } read_payload_t;

  logic begin_valid;
  begin_payload_t begin_payload;
  logic beat_valid;
  beat_payload_t beat_payload;
  read_payload_t read_payload;
  logic [DataWidth-1:0] read_data;

  modport controller(
      output begin_valid, begin_payload, beat_valid, beat_payload, read_payload,
      input read_data
  );
  modport array(
      input begin_valid, begin_payload, beat_valid, beat_payload, read_payload,
      output read_data
  );
  modport monitor(
      input begin_valid, begin_payload, beat_valid, beat_payload, read_payload, read_data
  );
endinterface

/* verilator lint_on DECLFILENAME */
