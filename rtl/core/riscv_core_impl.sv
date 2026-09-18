// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 五级顺序 RV32 核心。
//
// 连接 IF、ID、EX、MEM、WB 流水级与顶层 GPR/CSR，以及流水控制与仿真期观察通路。
module riscv_core_impl
  import riscv_bus_pkg::*;
  import riscv_core_pkg::*;
#(
  parameter int unsigned FetchOutstandingDepth = 1,
  parameter int unsigned IfIdQueueDepth = 2,
  parameter int unsigned ExMaxInflight = 1,
  parameter int unsigned MemMaxInflight = 1
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input pc_t boot_pc_i,

  // 连接层保留完整接口，供流水级以 master、观察模块以 monitor 视图使用。
  core_bus_if imem,
  core_bus_if dmem,

`ifndef SYNTHESIS
  // 调试与性能观测
  retire_debug_if.producer debug_retire,
  performance_debug_if.producer performance,
`endif

  // 由提交的 FENCE.I 产生的单周期 I-cache 失效请求
  output logic icache_invalidate_o
);

  //////////////////
  // 流水级间接口 //
  //////////////////
  if_id_if if_id ();
  id_ex_if id_ex ();
  ex_mem_if ex_mem ();
  mem_wb_if mem_wb ();

  redirect_if ex_redirect ();
  redirect_if wb_redirect ();
  redirect_if resolved_redirect ();
  csr_read_if csr_read ();
  csr_commit_if csr_commit ();
  csr_status_if csr_status ();
  commit_event_if commit_event ();
  gpr_read_if gpr_read ();
  writeback_if mem_wb_forward ();
  writeback_if wb ();

  logic serialize_block;
  logic serialize_ready;
  logic mem_busy;
  logic mem_side_effect_block;
  logic backend_flush;

`ifndef SYNTHESIS
  csr_state_if csr_state ();
`endif

  //////////////////////////
  // 全局改道与串行化控制 //
  //////////////////////////

  pipeline_ctrl u_pipeline_ctrl (
    .id_ex,
    .ex_mem,
    .mem_wb,
    .ex_redirect,
    .wb_redirect,
    .mem_busy_i(mem_busy),
    .serialize_block_o(serialize_block),
    .serialize_ready_o(serialize_ready),
    .mem_side_effect_block_o(mem_side_effect_block),
    .resolved_redirect,
    .backend_flush_o(backend_flush)
  );

  ////////////////////////////////
  // 架构状态、流水级与观察器   //
  ////////////////////////////////

  if_stage #(
    .FetchOutstandingDepth(FetchOutstandingDepth),
    .IfIdQueueDepth(IfIdQueueDepth)
  ) u_if_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .boot_pc_i(boot_pc_i),
    // 当前按多周期占用运行：下一条取指等待本条 WB 提交。流水结构与在途参数保留。
    .retire_i(mem_wb.valid && mem_wb.ready),
    .redirect(resolved_redirect),
    .imem,
    .if_id
  );

  id_stage u_id_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .flush_i(backend_flush),
    .serialize_block_i(serialize_block),
    .if_id,
    .id_ex,
    .gpr_read
  );

  regfile u_regfile (
    .clk_i,
    .gpr_read,
    .wb
  );

  ex_stage u_ex_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .flush_i(backend_flush),
    .serialize_ready_i(serialize_ready),
    .id_ex,
    .mem_wb(mem_wb_forward),
    .csr_read,
    .redirect(ex_redirect),
    .ex_mem
  );

  mem_stage u_mem_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .flush_i(backend_flush),
    .side_effect_block_i(mem_side_effect_block),
    .ex_mem,
    .dmem,
    .mem_wb_forward,
    .mem_wb,
    .busy_o(mem_busy)
  );

  wb_stage u_wb_stage (
    .clk_i,
    .rst_ni,
    .mem_wb,
    .csr_commit,
    .csr_status,
    .commit_event,
    .redirect(wb_redirect),
    .icache_invalidate_o,
    .wb
  );

  csr_unit u_csr_unit (
    .clk_i,
    .rst_ni,
    .csr_read,
    .commit(csr_commit),
`ifndef SYNTHESIS
    .state(csr_state),
`endif
    .status(csr_status)
  );

`ifndef SYNTHESIS
  performance_stats u_performance_stats (
    .clk_i,
    .rst_ni,
    .if_id,
    .id_ex,
    .ex_mem,
    .mem_wb,
    .redirect(resolved_redirect),
    .flush_backend_i(backend_flush),
    .imem,
    .dmem,
    // 当前按多周期占用运行：后端执行时主动停取，不属于 IF 供给不足。
    .if_local_stall_enable_i(!(id_ex.valid || ex_mem.valid || mem_wb.valid || mem_busy)),
    .performance
  );

  retire_debug #(
    .ExMaxInflight(ExMaxInflight),
    .MemMaxInflight(MemMaxInflight)
  ) u_retire_debug (
    .clk_i,
    .rst_ni,
    .flush_backend_i(backend_flush),
    .id_ex,
    .ex_mem,
    .mem_wb,
    .ex_redirect,
    .wb_redirect,
    .wb,
    .csr_state,
    .commit_event,
    .debug_retire
  );
`endif

endmodule
