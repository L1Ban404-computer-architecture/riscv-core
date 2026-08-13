// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// cache 子系统的公共命名空间。这里只保存跨 cache 模块共享、且不依赖具体实例几何
// 的默认参数、语义类型和纯函数；总线协议结构仍由 riscv_bus_pkg 独立拥有。
package cache_pkg;

  // cache 顶层参数的默认值。它们只提供一致的实例化基线，不参与固定 package 类型宽度；
  // BlockBytes/SetCount/WayCount 等几何相关宽度仍由每个 cache 实例自行推导。
  // verilator lint_off UNUSEDPARAM
  localparam bit CacheDefaultReadOnly = 1'b0;
  localparam int unsigned CacheDefaultBlockBytes = 16;
  localparam int unsigned CacheDefaultSetCount = 64;
  localparam int unsigned CacheDefaultWayCount = 2;
  localparam int unsigned CacheDefaultLookupLatency = 1;
  localparam int unsigned CacheDefaultMaxOutstanding = 2;
  // verilator lint_on UNUSEDPARAM

  // array 共享一个写入口：word 写用于提交 store hit，line 写用于安装 refill 结果。
  // 使用枚举明确两类操作，避免调用方依赖布尔值的隐含编码含义。
  typedef enum logic {
    CacheWriteWord,
    CacheWriteLine
  } cache_array_write_kind_e;

  // cache 参数合法性检查使用的二次幂判定；零不属于二次幂。
  function automatic bit cache_is_power_of_two(input int unsigned value);
    return (value > 0) && ((value & (value - 1)) == 0);
  endfunction

  // 按 CoreBus byte strobe 合并 store 数据。未置位的 lane 保留 old_word，置位的 lane
  // 完整取自 new_word；调用方必须保证 new_word 已按目标地址对齐到对应总线 lane。
  function automatic riscv_common_pkg::word_t cache_merge_store_word(
    input riscv_common_pkg::word_t old_word,
    input riscv_common_pkg::word_t new_word,
    input riscv_common_pkg::byte_en_t strobe
  );
    riscv_common_pkg::word_t byte_mask;

    byte_mask = '0;
    for (int unsigned lane = 0; lane < riscv_common_pkg::StrbW; lane++) begin
      byte_mask[lane * riscv_common_pkg::ByteW +: riscv_common_pkg::ByteW] =
          {riscv_common_pkg::ByteW{strobe[lane]}};
    end
    return (old_word & ~byte_mask) | (new_word & byte_mask);
  endfunction

endpackage
