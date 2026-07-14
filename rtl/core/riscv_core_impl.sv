// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module riscv_core_impl #(
  parameter int unsigned FetchOutstandingDepth = 1,
  parameter int unsigned IfIdQueueDepth = 2,
  parameter int unsigned MemOutstandingDepth = 1
) (
  input logic clk_i,
  input logic rst_ni,

  // 启动 PC 由上层 SoC 或测试平台提供。当前顶层只把它交给 IF stage，
  // 后续 IF stage 内部会维护真实 PC 寄存器、取指请求队列和 redirect 处理。
  input pc_t boot_pc_i,

  // ---------------------------------------------------------------------------
  // CoreBus 取指接口
  // ---------------------------------------------------------------------------
  //
  // IF 只发起 wstrb=0 的固定字宽读事务。
  output core_bus_req_t imem_req_o,
  input core_bus_resp_t imem_resp_i,

  // ---------------------------------------------------------------------------
  // CoreBus 数据接口
  // ---------------------------------------------------------------------------
  //
  // MEM stage 负责把流水线访存转换为统一的顺序 CoreBus 请求。为保证异常前
  // 不存在无法撤销的年轻 store，数据侧当前只允许一个 outstanding 请求。
  output core_bus_req_t dmem_req_o,
  input core_bus_resp_t dmem_resp_i,

  // core_debug_o 是面向仿真环境的扁平退休追踪总线。
  // 当 core_debug_o.valid 为 1 时，表示 WB stage 本周期退休一条指令。
  output core_debug_bus_t core_debug_o
);

  // ---------------------------------------------------------------------------
  // 阶段间事务通道
  // ---------------------------------------------------------------------------
  //
  // valid/ready 属于 stage 间流控；payload 使用 riscv_core_pkg 中定义的
  // 阶段事务类型。具体寄存器墙/FIFO 属于各 stage 内部，顶层只负责连线。
  logic if_id_valid;
  logic if_id_ready;
  if_id_bus_t if_id_bus;

  logic id_ex_valid;
  logic id_ex_ready;
  id_ex_bus_t id_ex_bus;

  logic ex_mem_valid;
  logic ex_mem_ready;
  ex_mem_bus_t ex_mem_bus;

  logic mem_wb_valid;
  logic mem_wb_ready;
  mem_wb_bus_t mem_wb_bus;

  // ---------------------------------------------------------------------------
  // redirect、前递和写回旁路
  // ---------------------------------------------------------------------------
  //
  // 顶层集中仲裁两类 redirect：EX 分支/JAL/JALR 仅清除错误路径前端；
  // WB trap/MRET 年龄更老，具有最高优先级并同时产生 pipeline_kill。
  redirect_bus_t redirect_bus;
  redirect_bus_t branch_redirect;
  redirect_bus_t commit_redirect;
  logic pipeline_kill;
  logic serialize_block;
  logic serialize_ready;
  logic mem_busy;
  logic mem_side_effect_block;

  csr_addr_t csr_read_addr;
  logic csr_read_valid;
  word_t csr_read_data;
  csr_write_bus_t csr_write;
  logic trap_commit;
  pc_t trap_epc;
  exception_bus_t trap_exception;
  logic mret_commit;
  word_t csr_mstatus;
  word_t csr_mtvec;
  word_t csr_mepc;
  word_t csr_mcause;
  word_t csr_mtval;
  word_t csr_current_mtvec;
  word_t csr_current_mepc;

  // 写回请求同时承担寄存器堆写回和 MEM/WB 数据前递角色。EX/MEM 候选
  // 由 EX stage 内部保存，不再经过顶层绕回。
  wb_req_bus_t mem_wb_req;
  wb_req_bus_t mem_pending_wb_req[MemOutstandingDepth];
  wb_req_bus_t wb_wb_req;

  // 精确异常要求“更老者获胜”。同周期 WB 提交异常与 EX 分支竞争时，
  // 必须采用 WB 目标，年轻分支随后由 pipeline_kill 清除。
  always_comb begin
    redirect_bus = branch_redirect;
    if (commit_redirect.valid) redirect_bus = commit_redirect;
  end

  // CSR/SYSTEM 在 ID/EX 至 WB 期间构成串行屏障。它进入 EX 前先等待更老
  // EX/MEM、LSU outstanding 和 MEM/WB 排空，因此 CSR 读取无需专用前递。
  assign serialize_block =
      (id_ex_valid && (id_ex_bus.ctrl.serialize || id_ex_bus.exception.valid)) ||
      (ex_mem_valid && (ex_mem_bus.commit.serialize || ex_mem_bus.exception.valid)) ||
      (mem_wb_valid && (mem_wb_bus.commit.serialize || mem_wb_bus.exception.valid));
  assign serialize_ready = !ex_mem_valid && !mem_busy && !mem_wb_valid;
  assign mem_side_effect_block = mem_wb_valid &&
      (mem_wb_bus.commit.serialize || mem_wb_bus.exception.valid);

  if_stage #(
    .FetchOutstandingDepth(FetchOutstandingDepth),
    .IfIdQueueDepth(IfIdQueueDepth)
  ) u_if_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .boot_pc_i(boot_pc_i),
    .redirect_i(redirect_bus),
    .imem_req_o(imem_req_o),
    .imem_resp_i(imem_resp_i),
    .if_id_valid_o(if_id_valid),
    .if_id_ready_i(if_id_ready),
    .if_id_bus_o(if_id_bus)
  );

  id_stage u_id_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .kill_i(pipeline_kill),
    .serialize_block_i(serialize_block),
    .if_id_valid_i(if_id_valid),
    .if_id_ready_o(if_id_ready),
    .if_id_bus_i(if_id_bus),
    .wb_req_i(wb_wb_req),
    .id_ex_valid_o(id_ex_valid),
    .id_ex_ready_i(id_ex_ready),
    .id_ex_bus_o(id_ex_bus)
  );

  ex_stage #(
    .MemOutstandingDepth(MemOutstandingDepth)
  ) u_ex_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .kill_i(pipeline_kill),
    .serialize_ready_i(serialize_ready),
    .id_ex_valid_i(id_ex_valid),
    .id_ex_ready_o(id_ex_ready),
    .id_ex_bus_i(id_ex_bus),
    .mem_pending_wb_req_i(mem_pending_wb_req),
    .mem_wb_req_i(mem_wb_req),
    .csr_read_addr_o(csr_read_addr),
    .csr_read_valid_i(csr_read_valid),
    .csr_read_data_i(csr_read_data),
    .redirect_o(branch_redirect),
    .ex_mem_valid_o(ex_mem_valid),
    .ex_mem_ready_i(ex_mem_ready),
    .ex_mem_bus_o(ex_mem_bus)
  );

  mem_stage #(
    .MemOutstandingDepth(MemOutstandingDepth)
  ) u_mem_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .kill_i(pipeline_kill),
    .side_effect_block_i(mem_side_effect_block),
    .ex_mem_valid_i(ex_mem_valid),
    .ex_mem_ready_o(ex_mem_ready),
    .ex_mem_bus_i(ex_mem_bus),
    .dmem_req_o(dmem_req_o),
    .dmem_resp_i(dmem_resp_i),
    .mem_pending_wb_req_o(mem_pending_wb_req),
    .mem_wb_req_o(mem_wb_req),
    .mem_wb_valid_o(mem_wb_valid),
    .mem_wb_ready_i(mem_wb_ready),
    .mem_wb_bus_o(mem_wb_bus),
    .busy_o(mem_busy)
  );

  csr_unit u_csr_unit (
    .clk_i,
    .rst_ni,
    .read_addr_i(csr_read_addr),
    .read_valid_o(csr_read_valid),
    .read_data_o(csr_read_data),
    .write_i(csr_write),
    .trap_i(trap_commit),
    .trap_epc_i(trap_epc),
    .trap_exception_i(trap_exception),
    .mret_i(mret_commit),
    .mstatus_o(csr_mstatus),
    .mtvec_o(csr_mtvec),
    .mepc_o(csr_mepc),
    .mcause_o(csr_mcause),
    .mtval_o(csr_mtval),
    .current_mtvec_o(csr_current_mtvec),
    .current_mepc_o(csr_current_mepc)
  );

  wb_stage u_wb_stage (
    .mem_wb_valid_i(mem_wb_valid),
    .mem_wb_ready_o(mem_wb_ready),
    .mem_wb_bus_i(mem_wb_bus),
    .csr_mstatus_i(csr_mstatus),
    .csr_mtvec_i(csr_mtvec),
    .csr_mepc_i(csr_mepc),
    .csr_mcause_i(csr_mcause),
    .csr_mtval_i(csr_mtval),
    .csr_current_mtvec_i(csr_current_mtvec),
    .csr_current_mepc_i(csr_current_mepc),
    .csr_write_o(csr_write),
    .trap_commit_o(trap_commit),
    .trap_epc_o(trap_epc),
    .trap_exception_o(trap_exception),
    .mret_commit_o(mret_commit),
    .commit_redirect_o(commit_redirect),
    .pipeline_kill_o(pipeline_kill),
    .wb_req_o(wb_wb_req),
    .core_debug_o(core_debug_o)
  );

endmodule
