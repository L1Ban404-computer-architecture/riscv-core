// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`ifndef CORE_BUS_TYPES_SVH
`define CORE_BUS_TYPES_SVH

`include "riscv_core_config.svh"

// CoreBus 是 core 与取指存储器、数据存储器或一级 cache 之间的轻量级
// 顺序事务接口。每周期最多接受一个请求，但允许存在多个 outstanding 请求；
// slave 必须为每个请求（包括写请求）按接受顺序返回且只返回一个响应。
//
// 请求携带完整有效地址与访问宽度。write 独立表示事务方向，wstrb 只表示
// 写请求的有效 byte lane；写数据和窄读响应均按照 addr 对应的总线 lane 对齐。
typedef struct packed {
  word_t addr;
  logic write;
  mem_size_e size;
  word_t wdata;
  byte_en_t wstrb;
} core_bus_req_chan_t;

typedef struct packed {
  word_t rdata;
  logic error;
} core_bus_rsp_chan_t;

// master -> slave：请求通道及响应通道 ready。
typedef struct packed {
  core_bus_req_chan_t req;
  logic req_valid;
  logic rsp_ready;
} core_bus_req_t;

// slave -> master：请求通道 ready 及响应通道。
typedef struct packed {
  logic req_ready;
  core_bus_rsp_chan_t rsp;
  logic rsp_valid;
} core_bus_resp_t;

`endif
