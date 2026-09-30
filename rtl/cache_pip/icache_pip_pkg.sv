// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 流水线式 I-cache 公共定义。
//
// 默认位宽与几何只在本 package 中给出。`cache_pip` 及其子模块、内部 interface
// 的实例参数以此为默认值，与阻塞式 `icache_pkg` 相互独立。
package icache_pip_pkg;

  parameter int unsigned ICachePipAddrWidth = 32;
  parameter int unsigned ICachePipDataWidth = 32;
  parameter int unsigned ICachePipBlockBytes = 4;
  parameter int unsigned ICachePipSetCount = 16;
  parameter int unsigned ICachePipWayCount = 1;

  // 满组时的牺牲路选择方式；存在无效路时三种策略均优先选择最低编号无效路。
  typedef enum logic [1:0] {
    ICACHE_PIP_REPLACEMENT_FIXED,
    ICACHE_PIP_REPLACEMENT_ROUND_ROBIN,
    ICACHE_PIP_REPLACEMENT_TREE_PLRU
  } icache_pip_replacement_policy_e;

  parameter icache_pip_replacement_policy_e ICachePipReplacementPolicy =
      ICACHE_PIP_REPLACEMENT_ROUND_ROBIN;

  // 几何参数统一要求为正二次幂，供各模块的 elaboration assertion 复用。
  function automatic bit icache_pip_is_power_of_two(input int unsigned value);
    return (value > 0) && ((value & (value - 1)) == 0);
  endfunction

endpackage
