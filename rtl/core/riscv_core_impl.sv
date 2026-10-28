// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 五级顺序 RV32 核心。
//
// 连接流水级、级间寄存器、前递、GPR/CSR、流水控制与仿真期观察通路。
module riscv_core_impl
  import riscv_bus_pkg::*;
  import riscv_core_pkg::*;
(
  // 全局控制
  input logic clk_i,
  // 低有效同步复位，由上游保持多个 clk_i 周期。
  input logic rst_ni,
  input pc_t boot_pc_i,

  core_bus_if imem,
  core_bus_if dmem,

  // 取消旧取指的延迟 redirect，以及 FENCE.I 执行时的取指状态失效请求。
  output logic imem_flush_o,
  output logic imem_invalidate_o
`ifndef SYNTHESIS
  , output logic debug_retire_valid_o,
  output riscv_debug_pkg::retire_debug_payload_t debug_retire_o,
  output riscv_debug_pkg::performance_debug_payload_t performance_o
`endif
);

  // 各级计算输出与寄存后的流水边界。
  if_id_if fetch_result ();
  if_id_if if_id ();
  id_ex_if decode_result ();
  id_ex_if id_ex ();
  ex_mem_if execute_result ();
  ex_mem_if ex_mem ();
  mem_wb_if memory_result ();
  mem_wb_if mem_wb ();

  redirect_if ex_redirect ();
  redirect_if wb_redirect ();
  branch_update_if branch_update ();
  csr_read_if csr_read ();
  csr_commit_if csr_commit ();
  csr_status_if csr_status ();
  gpr_read_if gpr_read ();
  id_ex_if forwarded ();
  gpr_write_if wb ();

  // 流水级与输出寄存器按 IF → ID → EX → MEM → WB 排列。

  if_stage u_if_stage (
    .clk_i,
    .rst_ni,
    .boot_pc_i,
    .ex_redirect,
    .wb_redirect,
    .branch_update,
    .imem_flush_o,
    .imem_invalidate_o,
    .imem,
    .result(fetch_result)
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.fetch)
`endif
  );

  // IF/ID 缓冲两笔事务，不直通；满队列即使当拍出队也不接受新输入。
  // 改道当拍屏蔽错误路径，时钟沿清空缓冲。
  fall_through_register #(
  // stream_fifo #(
  //   .Depth(1),
  //   .FallThrough(1'b1),
  //   .SameCycleRW(1'b1),
    .T(if_id_payload_t)
  ) u_if_id_register (
    .clk_i,
    .rst_ni,
    .flush_i(wb_redirect.valid || ex_redirect.valid),
    // .usage_o(  /* 未使用 */),
    .valid_i(fetch_result.valid),
    .ready_o(fetch_result.ready),
    .data_i(fetch_result.payload),
    .valid_o(if_id.valid),
    .ready_i(if_id.ready),
    .data_o(if_id.payload)
  );

  id_stage u_id_stage (
    .if_id(if_id),
    .result(decode_result),
    .gpr_read
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.decode)
`endif
  );

  // 各阶段组合结果直接前递到 ID；最新生产者尚未就绪时反压 ID。
  forwarding_unit u_forwarding_unit (
    .decoded(decode_result),
    .id_ex(id_ex),
    .ex_result(execute_result),
    .ex_mem(ex_mem),
    .mem_result(memory_result),
    .wb,
    .result(forwarded)
  );

  stream_register #(
    .T(id_ex_payload_t)
  ) u_id_ex_register (
    .clk_i,
    .rst_ni,
    .flush_i(wb_redirect.valid),
    .valid_i(forwarded.valid),
    .ready_o(forwarded.ready),
    .data_i(forwarded.payload),
    .valid_o(id_ex.valid),
    .ready_i(id_ex.ready),
    .data_o(id_ex.payload)
  );

  ex_stage u_ex_stage (
    .id_ex(id_ex),
    .older_inflight_i(ex_mem.valid || mem_wb.valid),
    .redirect(ex_redirect),
    .branch_update,
    .result(execute_result)
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.execute)
`endif
  );

  stream_register #(
    .T(ex_mem_payload_t)
  ) u_ex_mem_register (
    .clk_i,
    .rst_ni,
    .flush_i(wb_redirect.valid),
    .valid_i(execute_result.valid),
    .ready_o(execute_result.ready),
    .data_i(execute_result.payload),
    .valid_o(ex_mem.valid),
    .ready_i(ex_mem.ready),
    .data_o(ex_mem.payload)
  );

  mem_stage u_mem_stage (
    .clk_i,
    .rst_ni,
    .ex_mem(ex_mem),
    .dmem,
    .result(memory_result)
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.memory)
`endif
  );

  stream_register #(
    .T(mem_wb_payload_t)
  ) u_mem_wb_register (
    .clk_i,
    .rst_ni,
    // 发起改道的 WB 指令必须先提交；WB 恒 ready，提交后自然弹空。
    .flush_i(1'b0),
    .valid_i(memory_result.valid),
    .ready_o(memory_result.ready),
    .data_i(memory_result.payload),
    .valid_o(mem_wb.valid),
    .ready_i(mem_wb.ready),
    .data_o(mem_wb.payload)
  );

  wb_stage u_wb_stage (
    .mem_wb(mem_wb),
    .csr_read,
    .csr_commit,
    .csr_status,
    .redirect(wb_redirect),
    .wb
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.writeback)
`endif
  );

  // 架构状态：只接受 WB 提交。

  regfile u_regfile (
    .clk_i,
    .gpr_read,
    .wb
  );

  csr_unit u_csr_unit (
    .clk_i,
    .rst_ni,
    .csr_read,
    .commit(csr_commit),
    .status(csr_status)
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.csr)
`endif
  );

`ifndef SYNTHESIS
  generate
    begin : gen_debug
      import riscv_debug_pkg::*;

      core_debug_if bus ();
      pipeline_perf_classes_t debug_classes;

      retire_debug u_retire_debug (
        .clk_i,
        .rst_ni,
        .debug(bus),
        .classes_o(debug_classes),
        .retire_valid_o(debug_retire_valid_o),
        .retire_o(debug_retire_o)
      );

      performance_stats u_performance_stats (
        .clk_i,
        .rst_ni,
        .debug(bus),
        .classes_i(debug_classes),
        .performance_o
      );
    end
  endgenerate
`endif

endmodule
