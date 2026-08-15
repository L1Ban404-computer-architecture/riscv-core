// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 五级顺序 RV32 核心。
//
// 连接 IF、ID、EX、MEM、WB 流水级，并集中处理改道、串行化、数据前递和
// 性能观测通路。
module riscv_core_impl
  import riscv_bus_pkg::*;
  import riscv_core_pkg::*;
#(
  parameter int unsigned FetchOutstandingDepth = 1,
  parameter int unsigned IfIdQueueDepth = 2
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input pc_t boot_pc_i,

  // 存储器接口
  core_bus_if.master imem,
  core_bus_if.master dmem,

  // 调试与性能观测
  retire_debug_if.producer debug_retire,
  performance_debug_if.producer performance
);

  //////////////////
  // 流水级间接口 //
  //////////////////
  if_id_if if_id();
  id_ex_if id_ex();
  ex_mem_if ex_mem();
  mem_wb_if mem_wb();

  redirect_if ex_redirect();
  redirect_if wb_redirect();
  redirect_if resolved_redirect();
  csr_read_if csr_read();
  writeback_if mem_wb_forward();
  writeback_if wb();
  mem_pending_if mem_pending();

  logic serialize_block;
  logic serialize_ready;
  logic mem_busy;
  logic mem_side_effect_block;
  logic backend_flush;

  //////////////////////////
  // 全局改道与串行化控制 //
  //////////////////////////

  // 精确异常要求“更老者获胜”。同周期 WB 提交异常与 EX 分支竞争时，
  // 必须采用 WB 目标，年轻分支随后由后端 flush 清除。
  // 分支只需要刷新前端；WB 的 trap/MRET 同时刷新前端和后端。
  // WB 更老，因此它的目标地址覆盖同周期 EX 产生的分支目标。
  assign resolved_redirect.valid = wb_redirect.valid || ex_redirect.valid;
  assign resolved_redirect.target_pc = wb_redirect.valid ?
      wb_redirect.target_pc : ex_redirect.target_pc;
  // CSR/SYSTEM 在 ID/EX 至 WB 期间构成串行屏障。它进入 EX 前先等待更老
  // EX/MEM、LSU outstanding 和 MEM/WB 排空，因此 CSR 读取无需专用前递。
  assign serialize_block =
      (id_ex.valid && (id_ex.payload.ctrl.serialize ||
                       id_ex.payload.exception.valid)) ||
      (ex_mem.valid && (ex_mem.payload.commit.serialize ||
                        ex_mem.payload.exception.valid)) ||
      (mem_wb.valid && (mem_wb.payload.commit.serialize ||
                        mem_wb.payload.exception.valid));
  assign serialize_ready = !ex_mem.valid && !mem_busy && !mem_wb.valid;
  assign mem_side_effect_block = mem_wb.valid &&
      (mem_wb.payload.commit.serialize || mem_wb.payload.exception.valid);

  //////////////////////////
  // 流水级与性能统计实例 //
  //////////////////////////

  if_stage #(
    .FetchOutstandingDepth(FetchOutstandingDepth),
    .IfIdQueueDepth(IfIdQueueDepth)
  ) u_if_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .boot_pc_i(boot_pc_i),
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
    .wb,
    .id_ex
  );

  ex_stage u_ex_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .flush_i(backend_flush),
    .serialize_ready_i(serialize_ready),
    .id_ex,
    .mem_pending,
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
    .mem_pending,
    .mem_wb_forward,
    .mem_wb,
    .busy_o(mem_busy)
  );

  wb_stage u_wb_stage (
    .clk_i,
    .rst_ni,
    .mem_wb,
    .csr_read,
    .redirect(wb_redirect),
    .flush_o(backend_flush),
    .wb,
    .debug_retire
  );

  performance_stats u_performance_stats (
    .clk_i,
    .rst_ni,
    .if_id,
    .id_ex,
    .ex_mem,
    .mem_wb,
    .redirect(resolved_redirect),
    .flush_backend_i(backend_flush),
    .performance
  );

endmodule
