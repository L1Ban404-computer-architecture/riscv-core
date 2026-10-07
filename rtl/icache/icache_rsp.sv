// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 流水线 I-cache 的组合响应级，不增加流水级。
//
// 命中比较已在阵列完成，本级只消费 lookup payload。命中时用该拍读数据驱动
// CoreBus 响应；缺失时保持 miss 请求，直到 miss 响应与 CPU 响应同一拍完成。
// lookup.ready 等于这次响应握手，等待缺失期间阵列不再接收下一次查询。

module icache_rsp (
  // 查询结果、缺失事务与 CPU 响应。本级没有寄存器。
  icache_lookup_if.consumer lookup,
  icache_miss_if.master miss,
  core_bus_if.rsp_source core_bus
);

  logic lookup_hit;

  // valid 为低时 payload 可能未初始化。先与 valid 相与，避免命中位为 X 时把
  // 响应数据选成 X。
  assign lookup_hit = lookup.valid && lookup.payload.hit;
  assign miss.req_valid = lookup.valid && !lookup.payload.hit;
  assign miss.req_payload.addr = lookup.payload.addr;

  // CPU 响应只由已经形成的回应决定：命中数据，或 miss 响应。
  assign core_bus.rsp_valid = lookup_hit || miss.rsp_valid;
  assign core_bus.rsp_payload.rdata = lookup_hit ? lookup.payload.rdata : miss.rsp_payload.rdata;
  assign core_bus.rsp_payload.error = lookup_hit ? 1'b0 : miss.rsp_payload.error;
  assign lookup.ready = core_bus.rsp_fire;
  assign miss.rsp_ready = core_bus.rsp_ready;

endmodule
