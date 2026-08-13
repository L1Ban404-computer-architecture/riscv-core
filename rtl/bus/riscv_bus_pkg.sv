// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 处理器总线协议的唯一归属点。这里只定义 CoreBus、AXI4 的协议结构和协议常量；
// 数据宽度、标量类型与访问宽度来自 riscv_common_pkg，不在总线层重复拥有。
package riscv_bus_pkg;

  // CoreBus 每拍传输的有效字节数。编码等于 log2(字节数)，便于总线适配器扩展为
  // AXI AxSIZE；该类型属于 CoreBus ABI，与核心内部的访存操作枚举相互独立。
  typedef enum logic [1:0] {
    CORE_BUS_SIZE_BYTE = 2'd0,
    CORE_BUS_SIZE_HALF = 2'd1,
    CORE_BUS_SIZE_WORD = 2'd2
  } core_bus_size_e;

  // CoreBus 是处理器内部的轻量级顺序事务接口。请求携带完整 byte address；write
  // 表示方向，size 表示访问宽度，wdata/wstrb 已按地址对应的 byte lane 对齐。
  // req_valid/rsp_ready 由 master 驱动；每个被接受的请求（包括写请求）必须严格按序
  // 返回且只返回一个响应。
  typedef struct packed {
    riscv_common_pkg::word_t addr;
    logic write;
    core_bus_size_e size;
    riscv_common_pkg::word_t wdata;
    riscv_common_pkg::byte_en_t wstrb;
    logic req_valid;
    logic rsp_ready;
  } core_bus_req_t;

  // req_ready/rsp_valid 由 slave 驱动。窄读数据仍放在地址对应的总线 lane；error
  // 与 rsp_valid 同周期有效，写响应的 rdata 固定无语义。
  typedef struct packed {
    logic req_ready;
    riscv_common_pkg::word_t rdata;
    logic error;
    logic rsp_valid;
  } core_bus_resp_t;

  typedef logic [3:0] axi4_id_t;

  // AXI4 master 驱动的五通道 payload。字段宽度与公开顶层 ysyx_25080230 保持一致，
  // 同时覆盖占位 cache 的单拍事务和参数化 cache 的多拍 burst。
  typedef struct packed {
    // 写地址通道（AW）。
    logic awvalid;
    riscv_common_pkg::word_t awaddr;
    axi4_id_t awid;
    logic [7:0] awlen;
    logic [2:0] awsize;
    logic [1:0] awburst;

    // 写数据通道（W）。
    logic wvalid;
    riscv_common_pkg::word_t wdata;
    riscv_common_pkg::byte_en_t wstrb;
    logic wlast;

    // 写响应通道（B）的 ready。
    logic bready;

    // 读地址通道（AR）。
    logic arvalid;
    riscv_common_pkg::word_t araddr;
    axi4_id_t arid;
    logic [7:0] arlen;
    logic [2:0] arsize;
    logic [1:0] arburst;

    // 读数据通道（R）的 ready。
    logic rready;
  } axi4_req_t;

  // AXI4 slave 返回的握手和响应 payload，方向与 axi4_req_t 相反。
  typedef struct packed {
    // AW/W 通道 ready。
    logic awready;
    logic wready;

    // B 通道响应。
    logic bvalid;
    logic [1:0] bresp;
    axi4_id_t bid;

    // AR 通道 ready。
    logic arready;

    // R 通道响应。
    logic rvalid;
    logic [1:0] rresp;
    riscv_common_pkg::word_t rdata;
    logic rlast;
    axi4_id_t rid;
  } axi4_resp_t;

  // I/D cache 使用固定且互异的 AXI ID，汇聚器据此把读响应送回原请求端。
  localparam axi4_id_t ICACHE_AXI_ID = 4'd0;
  localparam axi4_id_t DCACHE_AXI_ID = 4'd1;

  // 当前 RTL 实际使用的 AXI 响应和 burst 编码。
  localparam logic [1:0] AXI4_RESP_OKAY = 2'b00;
  localparam logic [1:0] AXI4_BURST_INCR = 2'b01;

endpackage
