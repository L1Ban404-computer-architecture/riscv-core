// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

// Core-local performance statistics.  The event input is the actual WB
// retirement handshake, so the counters do not depend on the registered
// retire debug pulse or on any debug payload.
module performance_stats (
  input logic clk_i,
  input logic rst_ni,

  input logic retire_valid_i,
  output core_performance_debug_bus_t performance_debug_o
);

  logic [63:0] cycle_count_q;
  logic [63:0] instret_count_q;

  assign performance_debug_o = '{
    cycle_count: cycle_count_q,
    instret_count: instret_count_q
  };

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cycle_count_q <= '0;
      instret_count_q <= '0;
    end else begin
      cycle_count_q <= cycle_count_q + 64'd1;
      if (retire_valid_i) instret_count_q <= instret_count_q + 64'd1;
    end
  end

endmodule
