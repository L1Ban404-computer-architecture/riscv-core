// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 超小型 I-cache 公共定义。
//
// 默认几何只在本 package 中给出。`icache` 及其子模块、内部 interface 的实例参数
// 以此为默认值；`ysyx_25080230` 不覆盖，因此改这里即改 SoC 取指 cache。
// 替换策略作为 elaboration-time 参数使用，未选择的实现会由 generate 消除。
package icache_pkg;

  parameter int unsigned ICacheBlockBytes = 4;
  parameter int unsigned ICacheSetCount = 16;
  parameter int unsigned ICacheWayCount = 1;

  // 满组时的牺牲路选择方式；存在无效路时三种策略均优先选择最低编号无效路。
  typedef enum logic [1:0] {
    ICACHE_REPLACEMENT_FIXED,
    ICACHE_REPLACEMENT_ROUND_ROBIN,
    ICACHE_REPLACEMENT_TREE_PLRU
  } icache_replacement_policy_e;

  parameter icache_replacement_policy_e ICacheReplacementPolicy =
      ICACHE_REPLACEMENT_ROUND_ROBIN;

  // 几何参数统一要求为正二次幂，供各模块的 elaboration assertion 复用。
  function automatic bit icache_is_power_of_two(input int unsigned value);
    return (value > 0) && ((value & (value - 1)) == 0);
  endfunction

`ifndef SYNTHESIS
  // 仅供仿真观测。同拍 req+rsp 记为命中，其余请求/响应分别计入缺失时刻。
  typedef struct packed {
    logic [63:0] request_count;
    logic [63:0] hit_count;
    logic [127:0] hit_request_cycle_sum;
    logic [127:0] hit_response_cycle_sum;
    logic [127:0] miss_request_cycle_sum;
    logic [127:0] miss_response_cycle_sum;
  } icache_performance_payload_t;
`endif

endpackage
