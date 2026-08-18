// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Cache 默认参数、几何检查及按字节选通合并数据的公共函数。
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

  // Cache 维护操作只描述缓存层语义，不对应具体 ISA 指令。clean 写回所有脏行但保留
  // 缓存内容，invalidate 无条件丢弃所有缓存行。
  typedef enum logic {
    CACHE_MAINTENANCE_CLEAN_ALL,
    CACHE_MAINTENANCE_INVALIDATE_ALL
  } cache_maintenance_op_e;

  // cache 参数合法性检查使用的二次幂判定；零不属于二次幂。
  function automatic bit cache_is_power_of_two(input int unsigned value);
    return (value > 0) && ((value & (value - 1)) == 0);
  endfunction

endpackage
