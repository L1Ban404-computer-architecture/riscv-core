// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 流水线 I-cache 替换策略。
//
// 由阻塞式 `icache_replacement_policy` 复制并改为依赖 `icache_pip_pkg`。
// 存在无效路时始终选择最低编号无效路；只有目标组全部有效时，才使用固定 0 路、
// 逐组轮转或 Tree-PLRU 结果。策略是静态参数，generate 保证未选逻辑不进入综合网表。
// 命中更新以独热路向量输入，Tree-PLRU 更新直接沿独热掩码下推，避免 binary 译码。
`include "common/assertions.svh"

module cache_replacement_policy
  import icache_pip_pkg::*;
#(
  parameter int unsigned SetCount = ICachePipSetCount,
  parameter int unsigned WayCount = ICachePipWayCount,
  parameter icache_pip_replacement_policy_e ReplacementPolicy = ICachePipReplacementPolicy,
  localparam int unsigned SetIndexW = (SetCount > 1) ? $clog2(SetCount) : 1,
  localparam int unsigned WayIndexW = (WayCount > 1) ? $clog2(WayCount) : 1
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 当前目标组的牺牲路查询。`select_en_i` 为脉冲：输出该拍 victim 并把它
  // 视为已分配，下一拍起优先级已提高。查询组合结果可连续观察，但不得在
  // `select_en_i` 持续为高时每拍都更新。
  input  logic [SetIndexW-1:0] select_set_i,
  input  logic [WayCount-1:0]  select_valid_i,
  input  logic                 select_en_i,
  output logic [WayIndexW-1:0] victim_way_o,

  // 已完成命中的状态更新；`hit_oh_i` 为独热命中路，分配占用已并入 `select_en_i`。
  input logic                 hit_valid_i,
  input logic [SetIndexW-1:0] hit_set_i,
  input logic [WayCount-1:0]  hit_oh_i
);

  // 目标组满时由所选策略给出的牺牲路；最终输出还会经过 invalid-first 覆盖。
  logic [WayIndexW-1:0] full_victim;
  logic [WayCount-1:0] select_victim_oh;

  assign select_victim_oh = WayCount'(1) << victim_way_o;

  //////////////////////////
  // 满组牺牲路的静态实现 //
  //////////////////////////

  // 直接映射和固定策略不需要任何替换状态。
  if (WayCount == 1) begin : gen_direct_mapped
    assign full_victim = '0;

    // 1 路不读这些输入；赋值未被读取，综合会删除。
    logic unused_policy_inputs;
    assign unused_policy_inputs = ^{clk_i, rst_ni, select_set_i, select_en_i, hit_valid_i, hit_set_i,
                                    hit_oh_i, select_victim_oh};
  end else if (ReplacementPolicy == ICACHE_PIP_REPLACEMENT_FIXED) begin : gen_fixed
    assign full_victim = '0;

    logic unused_policy_inputs;
    assign unused_policy_inputs =
        ^{clk_i, rst_ni, select_set_i, select_en_i, hit_valid_i, hit_set_i, hit_oh_i,
          select_victim_oh};
  end else if (ReplacementPolicy == ICACHE_PIP_REPLACEMENT_ROUND_ROBIN) begin : gen_round_robin
    // 每组仅保存下一候选路。锁定牺牲路时向该路的下一路推进；hit 不影响轮转。
    // 一旦 `select_en_i` 脉冲，即使后续 refill 未完成也已消耗该候选。
    logic [WayIndexW-1:0] next_way_q[SetCount];

    assign full_victim = next_way_q[select_set_i];

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned set = 0; set < SetCount; set++) next_way_q[set] <= '0;
      end else if (select_en_i) begin
        if (victim_way_o == WayIndexW'(WayCount - 1)) next_way_q[select_set_i] <= '0;
        else next_way_q[select_set_i] <= victim_way_o + WayIndexW'(1);
      end
    end

    logic unused_hit;
    assign unused_hit = ^{hit_valid_i, hit_set_i, hit_oh_i, select_victim_oh};
  end else begin : gen_tree_plru
    // 二叉树共有 WayCount-1 个状态位；每个节点的 bit 指向当前较久未使用的子树。
    localparam int unsigned TreeBits = WayCount - 1;
    localparam int unsigned TreeLevels = $clog2(WayCount);

    logic [TreeBits-1:0] plru_q[SetCount];

    // 从根节点沿“较久未使用”方向下降，路径上的左右选择共同构成牺牲路编号。
    function automatic logic [WayIndexW-1:0] select_plru_way(
        input logic [TreeBits-1:0] tree);
      int unsigned node;
      logic [WayIndexW-1:0] way;
      logic direction;

      node = 0;
      way = '0;
      for (int unsigned level = 0; level < TreeLevels; level++) begin
        direction = tree[node];
        way = way << 1;
        way[0] = direction;
        node = (node * 2) + 1 + int'(direction);
      end
      return way;
    endfunction

    // 以独热访问向量更新：每层看当前子树右半是否命中，节点指向另一侧。
    // 同拍不必先 binary 编码命中路，掩码与或门即可。
    function automatic logic [TreeBits-1:0] update_plru_tree_oh(
        input logic [TreeBits-1:0] tree, input logic [WayCount-1:0] accessed_oh);
      int unsigned node;
      int unsigned lo;
      int unsigned hi;
      int unsigned mid;
      logic go_right;
      logic [TreeBits-1:0] updated_tree;
      logic [WayCount-1:0] right_mask;

      node = 0;
      lo = 0;
      hi = WayCount;
      updated_tree = tree;
      for (int unsigned level = 0; level < TreeLevels; level++) begin
        mid = (lo + hi) / 2;
        right_mask = '0;
        for (int unsigned way = 0; way < WayCount; way++) begin
          if ((way >= mid) && (way < hi)) right_mask[way] = 1'b1;
        end
        go_right = |(accessed_oh & right_mask);
        updated_tree[node] = !go_right;
        if (go_right) begin
          node = (node * 2) + 2;
          lo = mid;
        end else begin
          node = (node * 2) + 1;
          hi = mid;
        end
      end
      return updated_tree;
    endfunction

    assign full_victim = select_plru_way(plru_q[select_set_i]);

    // 命中和分配牺牲路都代表真实访问。同拍两者指向同一组时以后者覆盖。
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned set = 0; set < SetCount; set++) plru_q[set] <= '0;
      end else begin
        if (hit_valid_i)
          plru_q[hit_set_i] <= update_plru_tree_oh(plru_q[hit_set_i], hit_oh_i);
        if (select_en_i)
          plru_q[select_set_i] <= update_plru_tree_oh(plru_q[select_set_i], select_victim_oh);
      end
    end
  end

  //////////////////////
  // 无效路优先选择 //
  //////////////////////

  // 按路号从低到高扫描；找到第一条无效路后不再覆盖结果。
  always_comb begin
    logic invalid_found;

    victim_way_o = full_victim;
    invalid_found = 1'b0;
    for (int unsigned way = 0; way < WayCount; way++) begin
      if (!invalid_found && !select_valid_i[way]) begin
        victim_way_o = WayIndexW'(way);
        invalid_found = 1'b1;
      end
    end
  end

  //////////////
  // 参数与事件断言 //
  //////////////

  `ASSERT_INIT(CacheReplacementSetCountValid, icache_pip_is_power_of_two(SetCount))
  `ASSERT_INIT(CacheReplacementWayCountValid, icache_pip_is_power_of_two(WayCount))
  `ASSERT_INIT(
      CacheReplacementPolicyValid,
      (ReplacementPolicy == ICACHE_PIP_REPLACEMENT_FIXED) ||
          (ReplacementPolicy == ICACHE_PIP_REPLACEMENT_ROUND_ROBIN) ||
          (ReplacementPolicy == ICACHE_PIP_REPLACEMENT_TREE_PLRU))
  `ASSERT(CacheReplacementHitOhValid, hit_valid_i |-> $onehot(hit_oh_i), clk_i, !rst_ni)
  `ASSERT(CacheReplacementSelectWayValid, select_en_i |-> (int'(victim_way_o) < WayCount), clk_i,
          !rst_ni)

endmodule
