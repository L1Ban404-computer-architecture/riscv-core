// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

// Cache 内部接口。
//
// 定义控制器、阵列与缓存行 AXI 引擎之间的参数化请求和响应通道。

////////////////////
// Cache 维护事务 //
////////////////////

// Cache 顶层维护接口。请求一旦被接收便阻止新的普通访问；响应完成握手前只允许
// 一笔维护事务在途。
interface cache_maintenance_if;
  typedef struct packed {cache_pkg::cache_maintenance_op_e op;} req_payload_t;
  typedef struct packed {logic error;} rsp_payload_t;

  logic req_valid;
  logic req_ready;
  req_payload_t req_payload;
  logic rsp_valid;
  logic rsp_ready;
  rsp_payload_t rsp_payload;

  modport requester(
      output req_valid, req_payload, rsp_ready,
      input req_ready, rsp_valid, rsp_payload
  );
  modport handler(
      input req_valid, req_payload, rsp_ready,
      output req_ready, rsp_valid, rsp_payload
  );
  modport monitor(input req_valid, req_ready, req_payload, rsp_valid, rsp_ready, rsp_payload);
endinterface

// 维护控制器与 array 之间的扫描协议。array 返回的脏行保持到 line 握手；success
// 表示对应 AXI 写回是否成功，只有成功握手才允许清除 dirty。done 独立于脏行流，
// 因而空扫描也能可靠结束。
interface cache_array_maintenance_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned ByteWidth = 8,
  localparam int unsigned BlockAddrWidth = AddrWidth - $clog2(BlockBytes),
  localparam int unsigned LineWidth = BlockBytes * ByteWidth
);
  typedef struct packed {cache_pkg::cache_maintenance_op_e op;} req_payload_t;
  typedef struct packed {
    logic [BlockAddrWidth-1:0] block_addr;
    logic [LineWidth-1:0] line;
  } line_payload_t;

  logic req_valid;
  logic req_ready;
  req_payload_t req_payload;
  logic line_valid;
  logic line_ready;
  logic line_success;
  line_payload_t line_payload;
  logic done_valid;
  logic done_ready;

  modport controller(
      output req_valid, req_payload, line_ready, line_success, done_ready,
      input req_ready, line_valid, line_payload, done_valid
  );
  modport array(
      input req_valid, req_payload, line_ready, line_success, done_ready,
      output req_ready, line_valid, line_payload, done_valid
  );
  modport monitor(
      input req_valid, req_ready, req_payload, line_valid, line_ready, line_success, line_payload,
          done_valid, done_ready
  );
endinterface

//////////////////
// 阵列查询事务 //
//////////////////

// 阵列查询事务。txn_id 与 epoch 随请求返回，用于识别事务和
// 过滤旧代响应。响应为固定延迟通道，因此没有 ready 反压。
interface array_lookup_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned SetCount = cache_pkg::CacheDefaultSetCount,
  parameter int unsigned WayCount = cache_pkg::CacheDefaultWayCount,
  parameter int unsigned MaxOutstanding = cache_pkg::CacheDefaultMaxOutstanding,
  localparam int unsigned BlockOffsetWidth = $clog2(BlockBytes),
  localparam int unsigned SetIndexBits = $clog2(SetCount),
  localparam int unsigned SetIndexWidth = (SetCount > 1) ? SetIndexBits : 1,
  localparam int unsigned TagWidth = AddrWidth - BlockOffsetWidth - SetIndexBits,
  localparam int unsigned WordCount = BlockBytes / (DataWidth / 8),
  localparam int unsigned WordIndexWidth = (WordCount > 1) ? $clog2(WordCount) : 1,
  localparam int unsigned WayIndexWidth = (WayCount > 1) ? $clog2(WayCount) : 1,
  localparam int unsigned TxnIdWidth = (MaxOutstanding > 1) ? $clog2(MaxOutstanding) : 1
);
  typedef struct packed {
    logic [TxnIdWidth-1:0] txn_id;
    logic epoch;
    logic [SetIndexWidth-1:0] set;
    logic [TagWidth-1:0] tag;
    logic [WordIndexWidth-1:0] word;
  } req_payload_t;

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
  } rsp_payload_t;

  logic req_valid;
  logic req_ready;
  req_payload_t req_payload;
  logic rsp_valid;
  rsp_payload_t rsp_payload;

  modport requester(output req_valid, req_payload, input req_ready, rsp_valid, rsp_payload);
  modport handler(input req_valid, req_payload, output req_ready, rsp_valid, rsp_payload);
  modport monitor(input req_valid, req_ready, req_payload, rsp_valid, rsp_payload);
endinterface

//////////////////
// 阵列维护事务 //
//////////////////

// 牺牲行读取事务，用于 miss 替换前的脏行写回。
interface array_victim_if #(
  parameter int unsigned SetCount = cache_pkg::CacheDefaultSetCount,
  parameter int unsigned WayCount = cache_pkg::CacheDefaultWayCount,
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned ByteWidth = 8,
  localparam int unsigned SetIndexWidth = (SetCount > 1) ? $clog2(SetCount) : 1,
  localparam int unsigned WayIndexWidth = (WayCount > 1) ? $clog2(WayCount) : 1,
  localparam int unsigned LineWidth = BlockBytes * ByteWidth
);
  typedef struct packed {
    logic [SetIndexWidth-1:0] set;
    logic [WayIndexWidth-1:0] way;
  } req_payload_t;
  typedef struct packed {logic [LineWidth-1:0] line;} rsp_payload_t;

  logic req_valid;
  logic req_ready;
  req_payload_t req_payload;
  logic rsp_valid;
  logic rsp_ready;
  rsp_payload_t rsp_payload;

  modport requester(
      output req_valid, req_payload, rsp_ready,
      input req_ready, rsp_valid, rsp_payload
  );
  modport handler(
      input req_valid, req_payload, rsp_ready,
      output req_ready, rsp_valid, rsp_payload
  );
  modport monitor(input req_valid, req_ready, req_payload, rsp_valid, rsp_ready, rsp_payload);
endinterface

// 命中 store 的单字节掩码写接口，只更新目标路中被 strobe 选中的 byte lane。
interface array_word_write_if #(
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
interface array_line_install_if #(
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
// 缓存行 AXI 事务 //
////////////////////

// 缓存行读取事务。请求只描述行地址，响应返回完整缓存行和 AXI 错误状态。
interface axi_line_read_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned ByteWidth = 8,
  localparam int unsigned BlockAddrWidth = AddrWidth - $clog2(BlockBytes),
  localparam int unsigned LineWidth = BlockBytes * ByteWidth
);
  typedef struct packed {logic [BlockAddrWidth-1:0] block_addr;} req_payload_t;
  typedef struct packed {
    logic [LineWidth-1:0] line;
    logic error;
  } rsp_payload_t;

  logic req_valid;
  logic req_ready;
  req_payload_t req_payload;
  logic rsp_valid;
  logic rsp_ready;
  rsp_payload_t rsp_payload;

  modport requester(
      output req_valid, req_payload, rsp_ready,
      input req_ready, rsp_valid, rsp_payload
  );
  modport handler(
      input req_valid, req_payload, rsp_ready,
      output req_ready, rsp_valid, rsp_payload
  );
  modport monitor(input req_valid, req_ready, req_payload, rsp_valid, rsp_ready, rsp_payload);
endinterface

// 缓存行写回事务。请求包含行地址和完整数据，响应只报告 AXI 写事务是否成功。
interface axi_line_write_if #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned BlockBytes = cache_pkg::CacheDefaultBlockBytes,
  parameter int unsigned ByteWidth = 8,
  localparam int unsigned BlockAddrWidth = AddrWidth - $clog2(BlockBytes),
  localparam int unsigned LineWidth = BlockBytes * ByteWidth
);
  typedef struct packed {
    logic [BlockAddrWidth-1:0] block_addr;
    logic [LineWidth-1:0] line;
  } req_payload_t;
  typedef struct packed {logic error;} rsp_payload_t;

  logic req_valid;
  logic req_ready;
  req_payload_t req_payload;
  logic rsp_valid;
  logic rsp_ready;
  rsp_payload_t rsp_payload;

  modport requester(
      output req_valid, req_payload, rsp_ready,
      input req_ready, rsp_valid, rsp_payload
  );
  modport handler(
      input req_valid, req_payload, rsp_ready,
      output req_ready, rsp_valid, rsp_payload
  );
  modport monitor(input req_valid, req_ready, req_payload, rsp_valid, rsp_ready, rsp_payload);
endinterface
