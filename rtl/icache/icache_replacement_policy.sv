// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 超小型 I-cache 替换策略。
//
// 存在无效路时始终选择最低编号无效路；只有目标组全部有效时，才使用固定 0 路、
// 逐组轮转或 Tree-PLRU 结果。策略是静态参数，generate 保证未选逻辑不进入综合网表。
`include "common/assertions.svh"

module icache_replacement_policy
  import icache_pkg::*;
#(
  parameter int unsigned SetCount = 2,
  parameter int unsigned WayCount = 2,
  parameter icache_replacement_policy_e ReplacementPolicy = ICACHE_REPLACEMENT_ROUND_ROBIN,
  localparam int unsigned SetIndexW = (SetCount > 1) ? $clog2(SetCount) : 1,
  localparam int unsigned WayIndexW = (WayCount > 1) ? $clog2(WayCount) : 1
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 当前目标组的牺牲路查询
  input  logic [SetIndexW-1:0] select_set_i,
  input  logic [WayCount-1:0]  select_valid_i,
  output logic [WayIndexW-1:0] victim_way_o,

  // 已完成命中和成功回填的状态更新事件
  input logic                 hit_valid_i,
  input logic [SetIndexW-1:0] hit_set_i,
  input logic [WayIndexW-1:0] hit_way_i,
  input logic                 fill_valid_i,
  input logic [SetIndexW-1:0] fill_set_i,
  input logic [WayIndexW-1:0] fill_way_i
);

  // 目标组满时由所选策略给出的牺牲路；最终输出还会经过 invalid-first 覆盖。
  logic [WayIndexW-1:0] full_victim;

  //////////////////////////
  // 满组牺牲路的静态实现 //
  //////////////////////////

  // 直接映射和固定策略不需要任何替换状态。
  if (WayCount == 1) begin : gen_direct_mapped
    assign full_victim = '0;

    logic unused_policy_inputs;
    assign unused_policy_inputs = ^{clk_i, rst_ni, select_set_i, hit_valid_i, hit_set_i, hit_way_i,
                                    fill_valid_i, fill_set_i, fill_way_i};
  end else if (ReplacementPolicy == ICACHE_REPLACEMENT_FIXED) begin : gen_fixed
    assign full_victim = '0;

    logic unused_policy_inputs;
    assign unused_policy_inputs =
        ^{clk_i, rst_ni, select_set_i, hit_valid_i, hit_set_i, hit_way_i, fill_valid_i, fill_set_i,
          fill_way_i};
  end else if (ReplacementPolicy == ICACHE_REPLACEMENT_ROUND_ROBIN) begin : gen_round_robin
    // 每组仅保存下一候选路。只有成功 refill 才向已填充路的下一路推进；hit 不影响
    // 轮转顺序，失败 refill 也不会消耗一个候选位置。
    logic [WayIndexW-1:0] next_way_q[SetCount];

    assign full_victim = next_way_q[select_set_i];

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned set = 0; set < SetCount; set++) next_way_q[set] <= '0;
      end else if (fill_valid_i) begin
        if (fill_way_i == WayIndexW'(WayCount - 1)) next_way_q[fill_set_i] <= '0;
        else next_way_q[fill_set_i] <= fill_way_i + WayIndexW'(1);
      end
    end

    logic unused_hit;
    assign unused_hit = ^{hit_valid_i, hit_set_i, hit_way_i};
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

    // 访问一路后，将路径上每个节点改为指向另一侧，使刚访问的子树成为较新一侧。
    function automatic logic [TreeBits-1:0] update_plru_tree(
        input logic [TreeBits-1:0] tree, input logic [WayIndexW-1:0] accessed_way);
      int unsigned node;
      logic direction;
      logic [TreeBits-1:0] updated_tree;

      node = 0;
      updated_tree = tree;
      for (int unsigned level = 0; level < TreeLevels; level++) begin
        direction = accessed_way[TreeLevels-1-level];
        updated_tree[node] = !direction;
        node = (node * 2) + 1 + int'(direction);
      end
      return updated_tree;
    endfunction

    assign full_victim = select_plru_way(plru_q[select_set_i]);

    // 命中握手和成功回填都代表真实访问。两者在阻塞式控制器中不会同拍发生。
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned set = 0; set < SetCount; set++) plru_q[set] <= '0;
      end else begin
        if (hit_valid_i)
          plru_q[hit_set_i] <= update_plru_tree(plru_q[hit_set_i], hit_way_i);
        if (fill_valid_i)
          plru_q[fill_set_i] <= update_plru_tree(plru_q[fill_set_i], fill_way_i);
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

  `ASSERT_INIT(ICacheReplacementSetCountValid, icache_is_power_of_two(SetCount))
  `ASSERT_INIT(ICacheReplacementWayCountValid, icache_is_power_of_two(WayCount))
  `ASSERT_INIT(
      ICacheReplacementPolicyValid,
      (ReplacementPolicy == ICACHE_REPLACEMENT_FIXED) ||
          (ReplacementPolicy == ICACHE_REPLACEMENT_ROUND_ROBIN) ||
          (ReplacementPolicy == ICACHE_REPLACEMENT_TREE_PLRU))
  `ASSERT(ICacheReplacementHitWayValid,
          hit_valid_i |-> (int'(hit_way_i) < WayCount), clk_i, !rst_ni)
  `ASSERT(ICacheReplacementFillWayValid,
          fill_valid_i |-> (int'(fill_way_i) < WayCount), clk_i, !rst_ni)

endmodule
