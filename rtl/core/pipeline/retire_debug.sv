// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 退休调试观察器。
//
// 只监视公开握手、写回和 CSR 快照，不参与功能控制、不观察 CoreBus。
// 各级在途事务按入口/出口 fire 顺序入队出队；Depth 为该段最大在途数。
// EX 改道在 ID/EX fire 采样，访存请求在 EX/MEM fire 采样，提交快照在 MEM/WB fire
// 组装。后端 flush 在 posedge 清队列，不破坏当拍退休记录。
`ifndef SYNTHESIS
module retire_debug
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
#(
  parameter int unsigned ExMaxInflight = 1,
  parameter int unsigned MemMaxInflight = 1
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic flush_backend_i,

  // 流水与提交监视
  id_ex_if.monitor id_ex,
  ex_mem_if.monitor ex_mem,
  mem_wb_if.monitor mem_wb,
  redirect_if.monitor ex_redirect,
  redirect_if.monitor wb_redirect,
  writeback_if.monitor wb,
  csr_state_if.monitor csr_state,
  commit_event_if.monitor commit_event,

  // 退休观测
  retire_debug_if.producer debug_retire
);

  ////////////////////////
  // 旁路类型与握手     //
  ////////////////////////

  typedef struct packed {retire_redirect_payload_t redirect;} ex_sideband_t;

  typedef struct packed {
    retire_redirect_payload_t redirect;
    retire_mem_payload_t mem;
  } mem_sideband_t;

  logic id_ex_fire;
  logic ex_mem_fire;
  logic mem_wb_fire;
  ex_sideband_t ex_push;
  ex_sideband_t ex_pop;
  mem_sideband_t mem_push;
  mem_sideband_t mem_pop;
  retire_debug_payload_t debug_payload;

  assign id_ex_fire = id_ex.valid && id_ex.ready;
  assign ex_mem_fire = ex_mem.valid && ex_mem.ready;
  assign mem_wb_fire = mem_wb.valid && mem_wb.ready;

  ////////////////////////
  // 顺序在途队列       //
  ////////////////////////

  always_comb begin
    ex_push = '0;
    ex_push.redirect.valid = ex_redirect.valid;
    ex_push.redirect.target_pc = ex_redirect.payload.target_pc;

    mem_push = '0;
    mem_push.redirect = ex_pop.redirect;
    mem_push.mem.mem_op = !ex_mem.payload.mem_req.valid ? RETIRE_MEM_NONE :
        (ex_mem.payload.mem_req.write ? RETIRE_MEM_WRITE : RETIRE_MEM_READ);
    mem_push.mem.mem_size = ex_mem.payload.mem_req.size;
    mem_push.mem.mem_addr = ex_mem.payload.mem_req.addr;
    mem_push.mem.mem_data = ex_mem.payload.mem_req.wdata;
    if (ex_mem.payload.commit_ctx.exception.valid) mem_push.mem.mem_op = RETIRE_MEM_NONE;
  end

  retire_inflight_queue #(
    .Depth(ExMaxInflight),
    .T(ex_sideband_t)
  ) u_ex_queue (
    .clk_i,
    .rst_ni,
    .flush_i(flush_backend_i),
    .in_fire_i(id_ex_fire),
    .in_data_i(ex_push),
    .out_fire_i(ex_mem_fire),
    .out_data_o(ex_pop)
  );

  retire_inflight_queue #(
    .Depth(MemMaxInflight),
    .T(mem_sideband_t)
  ) u_mem_queue (
    .clk_i,
    .rst_ni,
    .flush_i(flush_backend_i),
    .in_fire_i(ex_mem_fire),
    .in_data_i(mem_push),
    .out_fire_i(mem_wb_fire),
    .out_data_o(mem_pop)
  );

  ////////////////////////
  // 退休快照组装       //
  ////////////////////////

  always_comb begin
    debug_payload = '0;
    debug_payload.meta = mem_wb.payload.meta;
    debug_payload.gpr_we = wb.payload.valid && wb.payload.data_valid;
    debug_payload.gpr_waddr = wb.payload.rd_addr;
    debug_payload.gpr_wdata = wb.payload.wdata;
    debug_payload.mem = mem_pop.mem;
    debug_payload.redirect = mem_pop.redirect;
    debug_payload.csr = csr_state.payload;
    if (debug_payload.mem.mem_op == RETIRE_MEM_READ)
      debug_payload.mem.mem_data = mem_wb.payload.wb_req.wdata;
    if (commit_event.valid &&
        ((commit_event.kind == COMMIT_TRAP) || (commit_event.kind == COMMIT_MRET)))
      debug_payload.mem.mem_op = RETIRE_MEM_NONE;
    // FENCE.I 的 PC+4 重取指是前端维护动作，不是架构控制流改道。
    if (commit_event.valid && (commit_event.kind != COMMIT_FENCE_I) && wb_redirect.valid) begin
      debug_payload.redirect.valid = 1'b1;
      debug_payload.redirect.target_pc = wb_redirect.payload.target_pc;
    end
  end

  assign debug_retire.valid = commit_event.valid;
  assign debug_retire.payload = debug_payload;

endmodule
`endif
