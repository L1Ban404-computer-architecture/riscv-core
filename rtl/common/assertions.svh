// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// 仿真期布尔检查。蕴含写成 `!条件 || 结论`，不使用 `|->`、`|=>`、`$stable` 或 `$bits`。
// 每个使用本宏的源文件都显式包含本头文件。

`ifndef RISCV_CORE_ASSERTIONS_SVH
`define RISCV_CORE_ASSERTIONS_SVH

`ifndef ASSERTS_OFF
`ifndef SYNTHESIS
`ifndef XSIM
`define INC_ASSERT
`endif
`endif
`endif

// 同拍布尔性质。clk、rst 可省略，默认 clk_i 与 !rst_ni。
`define CHECK(name, expr, clk = clk_i, rst = !rst_ni) \
`ifdef INC_ASSERT \
  name: assert property (@(posedge clk) disable iff (rst) (expr)); \
`endif

`endif
