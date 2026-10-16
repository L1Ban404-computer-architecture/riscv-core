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
  input logic rst_ni,
  input pc_t boot_pc_i,

  core_bus_if imem,
  core_bus_if dmem,

  // 取消旧取指的延迟 redirect，以及 FENCE.I 提交时的缓存失效请求。
  output logic imem_flush_o,
  output logic icache_invalidate_o
`ifndef SYNTHESIS
  , output logic debug_retire_valid_o,
  output riscv_debug_pkg::retire_debug_payload_t debug_retire_o,
  output riscv_debug_pkg::performance_debug_payload_t performance_o
`endif
);

  // 各级计算输出与寄存后的流水边界。
  if_id_if if_result ();
  if_id_if if_id ();
  id_ex_if id_result ();
  id_ex_if id_ex ();
  ex_mem_if ex_result ();
  ex_mem_if ex_mem ();
  mem_wb_if mem_result ();
  mem_wb_if mem_wb ();

  redirect_if ex_redirect ();
  redirect_if wb_redirect ();
  redirect_if resolved_redirect ();
  csr_read_if csr_read ();
  csr_commit_if csr_commit ();
  csr_status_if csr_status ();
  gpr_read_if gpr_read ();
  execute_operands_if operands ();
  gpr_write_if wb ();

  logic serialize_block;
  logic serialize_ready;
  logic mem_side_effect_block;
  logic backend_flush;

  // 流水级与输出寄存器按 IF → ID → EX → MEM → WB 排列。

  if_stage u_if_stage (
    .clk_i,
    .rst_ni,
    .boot_pc_i,
    .redirect(resolved_redirect),
    .imem_flush_o,
    .imem,
    .result(if_result)
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.fetch)
`endif
  );

  // IF/ID 空载直通；改道当拍屏蔽错误路径，时钟沿清空缓冲。
  fall_through_register #(
    .T(if_id_payload_t),
    .FlushMask(1'b1)
  ) u_if_id_register (
    .clk_i,
    .rst_ni,
    .flush_i(resolved_redirect.valid),
    .valid_i(if_result.valid),
    .ready_o(if_result.ready),
    .data_i(if_result.payload),
    .valid_o(if_id.valid),
    .ready_i(if_id.ready),
    .data_o(if_id.payload)
  );

  id_stage u_id_stage (
    .flush_i(backend_flush),
    .serialize_block_i(serialize_block),
    .if_id,
    .result(id_result),
    .gpr_read
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.decode)
`endif
  );

  stream_register #(
    .T(id_ex_payload_t)
  ) u_id_ex_register (
    .clk_i,
    .rst_ni,
    .flush_i(backend_flush),
    .valid_i(id_result.valid),
    .ready_o(id_result.ready),
    .data_i(id_result.payload),
    .valid_o(id_ex.valid),
    .ready_i(id_ex.ready),
    .data_o(id_ex.payload)
  );

  ex_stage u_ex_stage (
    .flush_i(backend_flush),
    .serialize_ready_i(serialize_ready),
    .id_ex,
    .operands,
    .csr_read,
    .redirect(ex_redirect),
    .result(ex_result)
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.execute)
`endif
  );

  stream_register #(
    .T(ex_mem_payload_t)
  ) u_ex_mem_register (
    .clk_i,
    .rst_ni,
    .flush_i(backend_flush),
    .valid_i(ex_result.valid),
    .ready_o(ex_result.ready),
    .data_i(ex_result.payload),
    .valid_o(ex_mem.valid),
    .ready_i(ex_mem.ready),
    .data_o(ex_mem.payload)
  );

  mem_stage u_mem_stage (
    .clk_i,
    .rst_ni,
    .flush_i(backend_flush),
    .side_effect_block_i(mem_side_effect_block),
    .ex_mem,
    .dmem,
    .result(mem_result)
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.memory)
`endif
  );

  stream_register #(
    .T(mem_wb_payload_t)
  ) u_mem_wb_register (
    .clk_i,
    .rst_ni,
    .flush_i(backend_flush),
    .valid_i(mem_result.valid),
    .ready_o(mem_result.ready),
    .data_i(mem_result.payload),
    .valid_o(mem_wb.valid),
    .ready_i(mem_wb.ready),
    .data_o(mem_wb.payload)
  );

  wb_stage u_wb_stage (
    .clk_i,
    .rst_ni,
    .mem_wb,
    .csr_commit,
    .csr_status,
    .redirect(wb_redirect),
    .icache_invalidate_o,
    .wb
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.writeback)
`endif
  );

  // 前递统一观察流水边界，向 EX 提供操作数和等待条件。

  forwarding_unit u_forwarding_unit (
    .clk_i,
    .rst_ni,
    .id_ex,
    .ex_mem,
    .mem_wb,
    .operands
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

  // 改道与串行化控制

  pipeline_ctrl u_pipeline_ctrl (
    .id_ex,
    .ex_mem,
    .mem_wb,
    .ex_redirect,
    .wb_redirect,
    .serialize_block_o(serialize_block),
    .serialize_ready_o(serialize_ready),
    .mem_side_effect_block_o(mem_side_effect_block),
    .resolved_redirect,
    .backend_flush_o(backend_flush)
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.control)
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
