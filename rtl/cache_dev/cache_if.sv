// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

// Cache 内部接口。
//
// 定义控制器、阵列与回填引擎之间的参数化请求和响应通道。

//////////////////
// 阵列查询事务 //
//////////////////

// 向阵列发起地址查询；txn_id 与 epoch 随请求返回，用于识别事务和过滤旧代响应。
interface cache_lookup_req_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned SetCount = cache_pkg::CacheDefaultSetCount,
  parameter int unsigned MaxOutstanding = cache_pkg::CacheDefaultMaxOutstanding,
  localparam int unsigned BlockOffsetWidth = $clog2(BlockBytes),
  localparam int unsigned SetIndexBits = $clog2(SetCount),
  localparam int unsigned SetIndexWidth = (SetCount > 1) ? SetIndexBits : 1,
  localparam int unsigned TagWidth = AddrWidth - BlockOffsetWidth - SetIndexBits,
  localparam int unsigned WordCount = BlockBytes / (DataWidth / 8),
  localparam int unsigned WordIndexWidth = (WordCount > 1) ? $clog2(WordCount) : 1,
  localparam int unsigned TxnIdWidth = (MaxOutstanding > 1) ? $clog2(MaxOutstanding) : 1
);
  typedef struct packed {
    logic [TxnIdWidth-1:0] txn_id;
    logic epoch;
    logic [SetIndexWidth-1:0] set;
    logic [TagWidth-1:0] tag;
    logic [WordIndexWidth-1:0] word;
  } payload_t;

  logic valid;
  logic ready;
  payload_t payload;

  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface

// 固定延迟的查询结果，包含命中信息、读取数据以及 miss 时建议的牺牲路。
interface cache_lookup_rsp_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned SetCount = cache_pkg::CacheDefaultSetCount,
  parameter int unsigned WayCount = cache_pkg::CacheDefaultWayCount,
  parameter int unsigned MaxOutstanding = cache_pkg::CacheDefaultMaxOutstanding,
  localparam int unsigned BlockOffsetWidth = $clog2(BlockBytes),
  localparam int unsigned SetIndexBits = $clog2(SetCount),
  localparam int unsigned TagWidth = AddrWidth - BlockOffsetWidth - SetIndexBits,
  localparam int unsigned WayIndexWidth = (WayCount > 1) ? $clog2(WayCount) : 1,
  localparam int unsigned TxnIdWidth = (MaxOutstanding > 1) ? $clog2(MaxOutstanding) : 1
);
  typedef struct packed {
    logic [TxnIdWidth-1:0] txn_id;
    logic epoch;
    logic hit;
    logic [WayIndexWidth-1:0] hit_way;
    logic [DataWidth-1:0] rdata;
    logic [WayIndexWidth-1:0] victim_way;
    logic [TagWidth-1:0] victim_tag;
    logic victim_valid;
    logic victim_dirty;
  } payload_t;

  logic valid;
  payload_t payload;

  modport producer(output valid, payload);
  modport consumer(input valid, payload);
  modport monitor(input valid, payload);
endinterface

//////////////////
// 阵列维护事务 //
//////////////////

// 请求读取指定组、指定路的完整牺牲行，用于 miss 替换前的脏行写回。
interface cache_victim_req_if #(
  parameter int unsigned SetCount = cache_pkg::CacheDefaultSetCount,
  parameter int unsigned WayCount = cache_pkg::CacheDefaultWayCount,
  localparam int unsigned SetIndexWidth = (SetCount > 1) ? $clog2(SetCount) : 1,
  localparam int unsigned WayIndexWidth = (WayCount > 1) ? $clog2(WayCount) : 1
);
  typedef struct packed {
    logic [SetIndexWidth-1:0] set;
    logic [WayIndexWidth-1:0] way;
  } payload_t;

  logic valid;
  logic ready;
  payload_t payload;
  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface

// 牺牲行读取响应；valid 与 dirty 决定回填引擎是否需要先执行 AXI 写回。
interface cache_victim_rsp_if #(
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned ByteWidth = 8,
  localparam int unsigned LineWidth = BlockBytes * ByteWidth
);
  typedef struct packed {logic [LineWidth-1:0] line;} payload_t;

  logic valid;
  logic ready;
  payload_t payload;
  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface

// 命中 store 的单字节掩码写接口，只更新目标路中被 strobe 选中的 byte lane。
interface cache_word_write_if #(
  parameter int unsigned DataWidth = 32,
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned SetCount = cache_pkg::CacheDefaultSetCount,
  parameter int unsigned WayCount = cache_pkg::CacheDefaultWayCount,
  localparam int unsigned SetIndexWidth = (SetCount > 1) ? $clog2(SetCount) : 1,
  localparam int unsigned WayIndexWidth = (WayCount > 1) ? $clog2(WayCount) : 1,
  localparam int unsigned WordCount = BlockBytes / (DataWidth / 8),
  localparam int unsigned WordIndexWidth = (WordCount > 1) ? $clog2(WordCount) : 1
);
  typedef struct packed {
    logic [SetIndexWidth-1:0] set;
    logic [WayIndexWidth-1:0] way;
    logic [WordIndexWidth-1:0] word;
    logic [DataWidth-1:0] data;
  } payload_t;

  logic valid;
  logic ready;
  payload_t payload;
  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface

// miss 完成后的整行安装接口，原子更新目标路的数据、标签、valid、dirty 和替换状态。
interface cache_line_install_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned SetCount = cache_pkg::CacheDefaultSetCount,
  parameter int unsigned WayCount = cache_pkg::CacheDefaultWayCount,
  parameter int unsigned ByteWidth = 8,
  localparam int unsigned BlockOffsetWidth = $clog2(BlockBytes),
  localparam int unsigned SetIndexBits = $clog2(SetCount),
  localparam int unsigned SetIndexWidth = (SetCount > 1) ? SetIndexBits : 1,
  localparam int unsigned TagWidth = AddrWidth - BlockOffsetWidth - SetIndexBits,
  localparam int unsigned WayIndexWidth = (WayCount > 1) ? $clog2(WayCount) : 1,
  localparam int unsigned LineWidth = BlockBytes * ByteWidth
);
  typedef struct packed {
    logic [SetIndexWidth-1:0] set;
    logic [WayIndexWidth-1:0] way;
    logic [LineWidth-1:0] data;
    logic [TagWidth-1:0] tag;
    logic dirty;
  } payload_t;

  logic valid;
  logic ready;
  payload_t payload;
  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface

////////////////////
// 写回与回填事务 //
////////////////////

// 控制面到回填引擎的替换事务；可同时携带待写回的脏牺牲行及新行地址。
interface cache_refill_req_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned ByteWidth = 8,
  localparam int unsigned BlockAddrWidth = AddrWidth - $clog2(BlockBytes),
  localparam int unsigned LineWidth = BlockBytes * ByteWidth
);
  typedef struct packed {
    logic [BlockAddrWidth-1:0] block_addr;
    logic writeback_valid;
    logic [BlockAddrWidth-1:0] writeback_block_addr;
    logic [LineWidth-1:0] writeback_data;
  } payload_t;

  logic valid;
  logic ready;
  payload_t payload;
  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface

// 回填引擎的完成响应，返回新缓存行并报告 AXI 访问是否发生错误。
interface cache_refill_rsp_if #(
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned ByteWidth = 8,
  localparam int unsigned LineWidth = BlockBytes * ByteWidth
);
  typedef struct packed {
    logic [LineWidth-1:0] data;
    logic error;
  } payload_t;

  logic valid;
  logic ready;
  payload_t payload;
  modport producer(output valid, payload, input ready);
  modport consumer(input valid, payload, output ready);
  modport monitor(input valid, ready, payload);
endinterface
