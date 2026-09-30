// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

// 流水线 I-cache 内部语义接口。
//
// `cache_lookup_if` 是阵列读结果的单向 stream：SRAM 读延迟一拍后，阵列以
// ready/valid 交出访问地址、读数据和命中标志。背压期间 valid 与 payload 保持。
//
// `cache_miss_if` 是单笔缺失事务。请求没有独立握手，地址随 lookup 保持到 CPU
// 响应完成；响应数据在 refill 写回提交后的下一拍才有效。
//
// `cache_refill_if` 是突发回填的地址/数据双通道，时序与握手约定见该 interface 注释。

//////////////////////
// 阵列读结果事务   //
//////////////////////

interface cache_lookup_if
  import icache_pip_pkg::*;
#(
  parameter int unsigned AddrWidth = ICachePipAddrWidth,
  parameter int unsigned DataWidth = ICachePipDataWidth
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

//////////////////////
// 缺失取数事务     //
//////////////////////

// 请求在整段缺失期间保持 valid 与 CPU 字地址，不设 req_ready。响应 valid 只能在
// refill 最后一拍写回的下一拍拉高，payload 保持到 rsp_ready。响应握手当拍请求
// 仍然有效；lookup 在该拍弹出，请求下一拍才撤销。处理器据此只在空闲时启动一次
// AXI 读，不能把持续为高的 req_valid 直接当作 AR。
interface cache_miss_if
  import icache_pip_pkg::*;
#(
  parameter int unsigned AddrWidth = ICachePipAddrWidth,
  parameter int unsigned DataWidth = ICachePipDataWidth
);
  typedef struct packed {logic [AddrWidth-1:0] addr;} req_payload_t;
  typedef struct packed {
    logic [DataWidth-1:0] rdata;
    logic error;
  } rsp_payload_t;

  req_payload_t req_payload;
  logic req_valid;

  rsp_payload_t rsp_payload;
  logic rsp_valid;
  logic rsp_ready;
  logic rsp_fire;

  assign rsp_fire = rsp_valid && rsp_ready;

  modport master(output req_payload, req_valid, rsp_ready, input rsp_payload, rsp_valid, rsp_fire);
  modport slave(input req_payload, req_valid, rsp_ready, rsp_fire, output rsp_payload, rsp_valid);
  modport monitor(input req_payload, req_valid, rsp_payload, rsp_valid, rsp_ready, rsp_fire);
endinterface

//////////////////////
// 缓存行回填事务   //
//////////////////////

// 地址/数据双通道突发回填。地址在整次 burst 期间保持 valid 与 payload，阵列不
// 锁存地址副本，仅在最后一拍数据握手时拉高 addr_ready。数据通道带 last 与
// commit：last 结束 burst 并解锁牺牲路，last 且 commit 才把该行标为有效。
// 时序要求：数据通道第一拍 valid 必须比地址通道第一拍 valid 至少晚一个周期，
// 以便阵列先锁存牺牲路与起始 line offset。
interface cache_refill_if
  import icache_pip_pkg::*;
#(
  parameter int unsigned AddrWidth = ICachePipAddrWidth,
  parameter int unsigned DataWidth = ICachePipDataWidth
);
  typedef struct packed {logic [AddrWidth-1:0] addr;} addr_payload_t;
  typedef struct packed {
    logic [DataWidth-1:0] data;
    logic last;
    logic commit;
  } data_payload_t;

  addr_payload_t addr_payload;
  logic addr_valid;
  logic addr_ready;
  logic addr_fire;

  data_payload_t data_payload;
  logic data_valid;
  logic data_ready;
  logic data_fire;

  assign addr_fire = addr_valid && addr_ready;
  assign data_fire = data_valid && data_ready;

  modport master(
      output addr_payload, addr_valid, data_payload, data_valid, input addr_ready, addr_fire,
          data_ready, data_fire
  );
  modport slave(
      input addr_payload, addr_valid, addr_fire, data_payload, data_valid, data_fire,
      output addr_ready, data_ready
  );
  modport monitor(
      input addr_payload, addr_valid, addr_ready, addr_fire, data_payload, data_valid, data_ready,
          data_fire
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
