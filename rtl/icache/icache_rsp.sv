// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 命中或首拍 miss 响应交给 CPU，响应握手时弹出 lookup。背景回填独立继续。

module icache_rsp (
  // 查询结果、缺失事务与 CPU 响应。本级没有寄存器。
  icache_lookup_if.consumer lookup,
  icache_miss_if.master miss,
  core_bus_if.rsp_source core_bus
);

  logic lookup_hit;

  assign lookup_hit = lookup.valid && lookup.payload.hit;
  // miss 在回填或响应未完成时不再接受请求；CPU 接受响应时 lookup 同时
  // 弹出，因此持续展示当前 miss 不会重复启动事务。
  assign miss.req_valid = lookup.valid && !lookup.payload.hit;
  assign miss.req_payload.addr = lookup.payload.addr;

  assign core_bus.rsp_valid = lookup_hit || miss.rsp_valid;
  assign core_bus.rsp_payload.rdata = lookup_hit ? lookup.payload.rdata : miss.rsp_payload.rdata;
  assign core_bus.rsp_payload.error = lookup_hit ? 1'b0 : miss.rsp_payload.error;
  assign lookup.ready = core_bus.rsp_fire;
  assign miss.rsp_ready = core_bus.rsp_ready;

endmodule
