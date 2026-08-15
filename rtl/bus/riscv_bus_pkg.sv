// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// CoreBus 和 AXI4 使用的协议常量与编码。
package riscv_bus_pkg;

  // CoreBus 每拍传输的有效字节数。编码等于 log2(字节数)，便于总线适配器扩展为
  // AXI AxSIZE；该类型属于 CoreBus ABI，与核心内部的访存操作枚举相互独立。
  typedef enum logic [1:0] {
    CORE_BUS_SIZE_BYTE = 2'd0,
    CORE_BUS_SIZE_HALF = 2'd1,
    CORE_BUS_SIZE_WORD = 2'd2,
    CORE_BUS_SIZE_DWORD = 2'd3
  } core_bus_size_e;

  // I/D cache 使用固定且互异的 AXI ID，汇聚器据此把读响应送回原请求端。
  localparam int unsigned ICACHE_AXI_ID = 0;
  localparam int unsigned DCACHE_AXI_ID = 1;

  // 当前 RTL 实际使用的 AXI 响应和 burst 编码。
  localparam logic [1:0] AXI4_RESP_OKAY = 2'b00;
  localparam logic [1:0] AXI4_BURST_INCR = 2'b01;

endpackage
