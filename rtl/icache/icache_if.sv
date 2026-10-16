// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

// 单笔查询结果 stream，背压期间保持地址、数据和命中标志。
interface icache_lookup_if
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = ICacheAddrWidth,
  parameter int unsigned DataWidth = ICacheDataWidth
);
  typedef struct packed {
    logic [AddrWidth-1:0] addr;
    logic [DataWidth-1:0] rdata;
    logic hit;
  } payload_t;

  payload_t payload;
  logic valid;
  logic ready;
  logic fire;

  assign fire = valid && ready;

  modport producer(output payload, valid, input ready, fire);
  modport consumer(input payload, valid, fire, output ready);
  modport monitor(input payload, valid, ready, fire);
endinterface

// req_fire 后请求归处理器所有，不再依赖 lookup 保持。首拍响应保持到 rsp_fire，
// 不受后续 beat 错误影响。回填和响应均完成后才接受下一笔 miss；背景回填不
// 阻塞其他 lookup 命中。
interface icache_miss_if
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = ICacheAddrWidth,
  parameter int unsigned DataWidth = ICacheDataWidth
);
  typedef struct packed {logic [AddrWidth-1:0] addr;} req_payload_t;
  typedef struct packed {
    logic [DataWidth-1:0] rdata;
    logic error;
  } rsp_payload_t;

  req_payload_t req_payload;
  logic req_valid;
  logic req_ready;
  logic req_fire;

  rsp_payload_t rsp_payload;
  logic rsp_valid;
  logic rsp_ready;
  logic rsp_fire;

  assign req_fire = req_valid && req_ready;
  assign rsp_fire = rsp_valid && rsp_ready;

  modport master(output req_payload, req_valid, rsp_ready,
      input req_ready, req_fire, rsp_payload, rsp_valid, rsp_fire);
  modport slave(input req_payload, req_valid, req_fire, rsp_ready, rsp_fire,
      output req_ready, rsp_payload, rsp_valid);
  modport monitor(input req_payload, req_valid, req_ready, req_fire,
      rsp_payload, rsp_valid, rsp_ready, rsp_fire);
endinterface

// valid 从 miss 接受当拍持续到末拍，包括 AR 等待及 beat 间隙。addr 是当前
// beat 字节地址，仅在 beat_valid 后推进，在 line 内回绕。beat_valid 表示本拍
// 写入，没有 ready。last 与 beat_valid 同时有效，error 为本拍及此前拍累计故障。
// 无错误末拍才置整行有效；首个 beat_valid 至少晚于 valid 开始一拍。
interface icache_refill_if
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = ICacheAddrWidth,
  parameter int unsigned DataWidth = ICacheDataWidth
);
  typedef struct packed {
    logic [DataWidth-1:0] data;
    logic last;
    logic error;
  } payload_t;

  logic valid;
  logic [AddrWidth-1:0] addr;
  logic beat_valid;
  payload_t payload;

  modport master(output valid, addr, beat_valid, payload);
  modport slave(input valid, addr, beat_valid, payload);
  modport monitor(input valid, addr, beat_valid, payload);
endinterface

`ifndef SYNTHESIS
interface icache_debug_if;
  riscv_bus_pkg::bus_debug_payload_t bus;
  logic lookup_valid;
  logic lookup_fire;
  logic lookup_hit;
  modport producer(output bus, lookup_valid, lookup_fire, lookup_hit);
  modport consumer(input bus, lookup_valid, lookup_fire, lookup_hit);
endinterface
`endif

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
