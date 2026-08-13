// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Per-set Tree-PLRU.  Invalid ways always win in ascending way order.  A PLRU
// node bit points at the subtree selected for the next replacement.
`include "common/assertions.svh"

module cache_replacement_policy
  import cache_pkg::*;
#(
  parameter int unsigned SetCount = CacheDefaultSetCount,
  parameter int unsigned WayCount = CacheDefaultWayCount,
  localparam int unsigned SetIndexW =
      (SetCount > 1) ? $clog2(SetCount) : 1,
  localparam int unsigned WayIndexW =
      (WayCount > 1) ? $clog2(WayCount) : 1
) (
  input logic clk_i,
  input logic rst_ni,

  input logic [SetIndexW-1:0] select_set_i,
  input logic [WayCount-1:0] select_valid_i,
  output logic [WayIndexW-1:0] victim_way_o,

  input logic access_valid_i,
  input logic [SetIndexW-1:0] access_set_i,
  input logic [WayIndexW-1:0] access_way_i
);

  if (WayCount == 1) begin : gen_direct_mapped
    assign victim_way_o = '0;

    logic unused_access;
    assign unused_access = ^{clk_i, rst_ni, select_set_i, select_valid_i,
                             access_valid_i, access_set_i, access_way_i};
  end else begin : gen_tree_plru
    localparam int unsigned TreeBits = WayCount - 1;
    localparam int unsigned TreeLevels = $clog2(WayCount);

    logic [TreeBits-1:0] plru_q[SetCount];
    logic [WayIndexW-1:0] plru_victim;

    function automatic logic [WayIndexW-1:0] select_plru_way(
      input logic [TreeBits-1:0] tree
    );
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

    function automatic logic [TreeBits-1:0] update_plru_tree(
      input logic [TreeBits-1:0] tree,
      input logic [WayIndexW-1:0] accessed_way
    );
      int unsigned node;
      logic direction;
      logic [TreeBits-1:0] updated_tree;

      node = 0;
      updated_tree = tree;
      for (int unsigned level = 0; level < TreeLevels; level++) begin
        direction = accessed_way[TreeLevels - 1 - level];
        updated_tree[node] = !direction;
        node = (node * 2) + 1 + int'(direction);
      end
      return updated_tree;
    endfunction

    assign plru_victim = select_plru_way(plru_q[select_set_i]);

    always_comb begin
      logic invalid_found;

      victim_way_o = plru_victim;
      invalid_found = 1'b0;
      for (int unsigned way = 0; way < WayCount; way++) begin
        if (!invalid_found && !select_valid_i[way]) begin
          victim_way_o = WayIndexW'(way);
          invalid_found = 1'b1;
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned set = 0; set < SetCount; set++) plru_q[set] <= '0;
      end else if (access_valid_i) begin
        plru_q[access_set_i] <= update_plru_tree(
          plru_q[access_set_i], access_way_i
        );
      end
    end

    `ASSERT(CacheReplacementAccessWayValid,
            access_valid_i |-> (int'(access_way_i) < WayCount),
            clk_i, !rst_ni,
            "A PLRU update must identify an implemented cache way.")
  end

  `ASSERT_INIT(CacheReplacementSetCountValid,
               cache_is_power_of_two(SetCount),
               "Tree-PLRU requires a positive power-of-two set count.")
  `ASSERT_INIT(CacheReplacementWayCountValid,
               cache_is_power_of_two(WayCount),
               "Tree-PLRU requires a positive power-of-two way count.")

endmodule
