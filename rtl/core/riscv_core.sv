// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module riscv_core (
  input logic clk_i,
  input logic rst_ni,

  // 启动 PC 由上层 SoC 或测试平台提供。当前顶层只把它交给 IF stage，
  // 后续 IF stage 内部会维护真实 PC 寄存器、取指请求队列和 redirect 处理。
  input pc_t boot_pc_i,

  // ---------------------------------------------------------------------------
  // AXI4-Lite 取指接口
  // ---------------------------------------------------------------------------
  //
  // IF 只发起读事务，但边界仍暴露完整 AXI4-Lite master 总线。
  // AW/W/B 通道由 IF stage 保持空闲。
  output axi_lite_req_t imem_req_o,
  input axi_lite_resp_t imem_resp_i,

  // ---------------------------------------------------------------------------
  // AXI4-Lite 数据接口
  // ---------------------------------------------------------------------------
  //
  // MEM stage 负责把流水线内的 mem_req_bus_t 转成完整 AXI4-Lite master
  // 事务：load 使用 AR/R，store 使用 AW/W/B。
  output axi_lite_req_t dmem_req_o,
  input axi_lite_resp_t dmem_resp_i,

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
  // redirect 从 EX 指向 IF，用于丢弃错误路径 fetch。当前 ID/EX 寄存器中的
  // 正是产生 redirect 的指令；IF 会在同周期屏蔽更年轻事务的 valid。
  redirect_bus_t redirect_bus;

  // 写回请求同时承担两个角色：
  // - WB stage 的 wb_req_bus 写回 ID stage 内部未来的寄存器堆。
  // - EX/MEM/WB 不同年龄的写回请求提供给 EX stage 做数据前递判断。
  wb_req_bus_t ex_wb_req;
  wb_req_bus_t mem_wb_req;
  wb_req_bus_t wb_wb_req;

  forward_src_bus_t forward_src_bus;

  assign forward_src_bus.ex_wb = ex_wb_req;
  assign forward_src_bus.mem_wb = mem_wb_req;
  assign forward_src_bus.wb_wb = wb_wb_req;

  if_stage u_if_stage (
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
    .if_id_valid_i(if_id_valid),
    .if_id_ready_o(if_id_ready),
    .if_id_bus_i(if_id_bus),
    .wb_req_i(wb_wb_req),
    .id_ex_valid_o(id_ex_valid),
    .id_ex_ready_i(id_ex_ready),
    .id_ex_bus_o(id_ex_bus)
  );

  ex_stage u_ex_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .id_ex_valid_i(id_ex_valid),
    .id_ex_ready_o(id_ex_ready),
    .id_ex_bus_i(id_ex_bus),
    .forward_src_i(forward_src_bus),
    .redirect_o(redirect_bus),
    .ex_wb_req_o(ex_wb_req),
    .ex_mem_valid_o(ex_mem_valid),
    .ex_mem_ready_i(ex_mem_ready),
    .ex_mem_bus_o(ex_mem_bus)
  );

  mem_stage u_mem_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .ex_mem_valid_i(ex_mem_valid),
    .ex_mem_ready_o(ex_mem_ready),
    .ex_mem_bus_i(ex_mem_bus),
    .dmem_req_o(dmem_req_o),
    .dmem_resp_i(dmem_resp_i),
    .mem_wb_req_o(mem_wb_req),
    .mem_wb_valid_o(mem_wb_valid),
    .mem_wb_ready_i(mem_wb_ready),
    .mem_wb_bus_o(mem_wb_bus)
  );

  wb_stage u_wb_stage (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .mem_wb_valid_i(mem_wb_valid),
    .mem_wb_ready_o(mem_wb_ready),
    .mem_wb_bus_i(mem_wb_bus),
    .wb_req_o(wb_wb_req),
    .core_debug_o(core_debug_o)
  );

endmodule
