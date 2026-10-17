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
  if_id_if if_result_buffered ();
  id_ex_if id_result ();
  id_ex_if id_result_buffered ();
  ex_mem_if ex_result ();
  ex_mem_if ex_result_buffered ();
  mem_wb_if mem_result ();
  mem_wb_if mem_result_buffered ();

  redirect_if ex_redirect ();
  redirect_if wb_redirect ();
  redirect_if resolved_redirect ();
  csr_read_if csr_read ();
  csr_commit_if csr_commit ();
  csr_status_if csr_status ();
  gpr_read_if gpr_read ();
  id_ex_if forward_result ();
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
    .T(if_id_payload_t)
  ) u_if_id_register (
    .clk_i,
    .rst_ni,
    .flush_i(resolved_redirect.valid),
    .valid_i(if_result.valid),
    .ready_o(if_result.ready),
    .data_i(if_result.payload),
    .valid_o(if_result_buffered.valid),
    .ready_i(if_result_buffered.ready),
    .data_o(if_result_buffered.payload)
  );

  id_stage u_id_stage (
    .serialize_block_i(serialize_block),
    .if_id(if_result_buffered),
    .result(id_result),
    .gpr_read
`ifndef SYNTHESIS
    , .debug_o(gen_debug.bus.decode)
`endif
  );

  // ID 操作数就绪后才写入 ID/EX；当前 EX 生产者匹配时反压 ID。
  forwarding_unit u_forwarding_unit (
    .decoded(id_result),
    .id_ex(id_result_buffered),
    .ex_mem(ex_result_buffered),
    .mem_wb(mem_result_buffered),
    .result(forward_result)
  );

  stream_register #(
    .T(id_ex_payload_t)
  ) u_id_ex_register (
    .clk_i,
    .rst_ni,
    .flush_i(backend_flush),
    .valid_i(forward_result.valid),
    .ready_o(forward_result.ready),
    .data_i(forward_result.payload),
    .valid_o(id_result_buffered.valid),
    .ready_i(id_result_buffered.ready),
    .data_o(id_result_buffered.payload)
  );

  ex_stage u_ex_stage (
    .serialize_ready_i(serialize_ready),
    .id_ex(id_result_buffered),
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
    .valid_o(ex_result_buffered.valid),
    .ready_i(ex_result_buffered.ready),
    .data_o(ex_result_buffered.payload)
  );

  mem_stage u_mem_stage (
    .clk_i,
    .rst_ni,
    .side_effect_block_i(mem_side_effect_block),
    .ex_mem(ex_result_buffered),
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
    // 发起改道的 WB 指令必须先提交；WB 恒 ready，提交后自然弹空。
    .flush_i(1'b0),
    .valid_i(mem_result.valid),
    .ready_o(mem_result.ready),
    .data_i(mem_result.payload),
    .valid_o(mem_result_buffered.valid),
    .ready_i(mem_result_buffered.ready),
    .data_o(mem_result_buffered.payload)
  );

  wb_stage u_wb_stage (
    .mem_wb(mem_result_buffered),
    .csr_commit,
    .csr_status,
    .redirect(wb_redirect),
    .icache_invalidate_o,
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

  // 改道与串行化控制

  pipeline_ctrl u_pipeline_ctrl (
    .id_ex(id_result_buffered),
    .ex_mem(ex_result_buffered),
    .mem_wb(mem_result_buffered),
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
