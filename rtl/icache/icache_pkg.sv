// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 超小型 I-cache 公共定义。
//
// 替换策略作为 elaboration-time 参数使用，未选择的实现会由 generate 消除。
package icache_pkg;

  // 满组时的牺牲路选择方式；存在无效路时三种策略均优先选择最低编号无效路。
  typedef enum logic [1:0] {
    ICACHE_REPLACEMENT_FIXED,
    ICACHE_REPLACEMENT_ROUND_ROBIN,
    ICACHE_REPLACEMENT_TREE_PLRU
  } icache_replacement_policy_e;

  // 几何参数统一要求为正二次幂，供各模块的 elaboration assertion 复用。
  function automatic bit icache_is_power_of_two(input int unsigned value);
    return (value > 0) && ((value & (value - 1)) == 0);
  endfunction

endpackage
