// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// 针对 riscv-core 调整：仅保留本地 RTL 使用且无外部依赖的 assertion 子集。
// 每个使用 assertion 宏的源文件都显式包含本头文件。

`ifndef RISCV_CORE_ASSERTIONS_SVH
`define RISCV_CORE_ASSERTIONS_SVH

`ifndef ASSERTS_OFF
`ifndef SYNTHESIS
`ifndef XSIM
`define INC_ASSERT
`endif
`endif
`endif

`ifdef ASSERTS_OVERRIDE_ON
`ifndef INC_ASSERT
`define INC_ASSERT
`endif
`endif

`define ASSERT_STRINGIFY(__x) `"__x`"

`ifndef ASSERT_RPT
`define ASSERT_RPT(__name, __desc = "") \
  $error("[ASSERT FAILED] [%m] %s: %s (%s:%0d)", __name, __desc, `__FILE__, `__LINE__);
`endif

`define ASSERT_DEFAULT_CLK clk_i
`define ASSERT_DEFAULT_RST !rst_ni

`define ASSERT_INIT(__name, __prop, __desc = "")       \
`ifdef INC_ASSERT                                      \
  initial begin                                        \
    __name: assert (__prop)                            \
      else begin                                       \
        `ASSERT_RPT(`ASSERT_STRINGIFY(__name), __desc) \
      end                                              \
  end                                                  \
`endif

`define ASSERT(__name, __prop, __clk = `ASSERT_DEFAULT_CLK, __rst = `ASSERT_DEFAULT_RST,
               __desc = "") \
`ifdef INC_ASSERT                                                                                     \
  __name: assert property (@(posedge __clk) disable iff ((__rst) !== '0) (__prop))                    \
    else begin                                                                                        \
      `ASSERT_RPT(`ASSERT_STRINGIFY(__name), __desc)                                                  \
    end                                                                                               \
`endif

`define ASSERT_STABLE(__name, __valid, __ready, __data, __mask = '0, __clk = `ASSERT_DEFAULT_CLK,
                      __rst = `ASSERT_DEFAULT_RST, __desc = "") \
`ifdef INC_ASSERT                                                                                                                           \
  `ASSERT(__name, (__valid) && !(__ready) |=> $stable((__data) & ~(__mask)), __clk, __rst, __desc)                                          \
`endif

`endif
