// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 观察分类退休数、局部背压和 CoreBus 延迟，不参与功能控制。
// 局部阻塞可能重叠，不能相加解释为总 CPI 损失。
`ifndef SYNTHESIS
module performance_stats
  import riscv_debug_pkg::*;
(
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  core_debug_if.consumer debug,
  input pipeline_perf_classes_t classes_i,

  // 性能观测
  output performance_debug_payload_t performance_o
);

  // 内部事件与计数状态

  logic if_id_stall;
  logic id_ex_stall;
  logic ex_mem_stall;
  logic mem_wb_stall;

  logic if_local_stall;
  logic id_local_stall;
  logic ex_local_stall;
  logic mem_local_stall;
  logic wb_local_stall;
  logic retire_fire;
  logic redirect;

  // 仅保存本模块负责的流水计数；访存统计由各自观察器维护。
  struct packed {
    logic [63:0] cycle_count;
    logic [63:0] instret_count;
    logic [63:0] redirect_count;
    logic [63:0] if_local_stall_cycle_count;
    class_performance_payload_t [PerfClassCount-1:0] classes;
  } stats_q;
  memory_performance_payload_t imem_stats, dmem_stats;

  memory_performance_stats u_imem_stats (
    .clk_i, .rst_ni,
    .flush_i(debug.fetch.imem_flush),
    .cycle_i(stats_q.cycle_count),
    .bus_i(debug.fetch.bus),
    .stats_o(imem_stats)
  );
  memory_performance_stats u_dmem_stats (
    .clk_i, .rst_ni,
    .flush_i(1'b0),
    .cycle_i(stats_q.cycle_count),
    .bus_i(debug.memory.bus),
    .stats_o(dmem_stats)
  );

  assign redirect = debug.execute.redirect || debug.writeback.redirect.valid;

  assign retire_fire = debug.writeback.valid && debug.writeback.ready;

  // 传输、阻塞与局部背压事件

  // fire 只表示边界上真实发生的事务传输。它不使用 flush 额外门控：流水边界与 stage 已经
  // 按功能语义决定当拍 valid/ready，统计侧必须保留 trap/MRET 退休等真实握手。

  // 原始 stall 表示边界上存在事务需求但接收端不能接受。redirect 或后端 flush
  // 会主动屏蔽 valid/ready 并清除错误路径事务，这种协议行为不是性能阻塞，因而
  // 在对应冲刷当拍从 stall 统计中排除。
  assign if_id_stall = debug.decode.valid && !debug.decode.ready && !redirect;
  assign id_ex_stall = debug.execute.valid && !debug.execute.ready && !debug.writeback.redirect.valid;
  assign ex_mem_stall = debug.memory.valid && !debug.memory.ready && !debug.writeback.redirect.valid;
  assign mem_wb_stall = debug.writeback.valid && !debug.writeback.ready &&
      !debug.writeback.redirect.valid;

  // IF 没有 core 内部的输入握手，因此不能按其他 stage 的入口阻塞方式统计。
  // 这里把“后端愿意接收而 IF/ID 没有事务”定义为 IF 供给不足；redirect 当拍
  // 不计入，但 redirect 后恢复取指导致的空泡仍会自然计入。
  assign if_local_stall = debug.decode.ready && !debug.decode.valid && !redirect;

  // 局部阻塞前沿用于剔除逐级向上传播的背压。某阶段阻挡了入口，而它的出口
  // 边界没有同时阻塞，说明这条背压链在该阶段开始。非相邻阶段可在同一周期
  // 各自形成独立前沿，所以这些计数器允许重叠，不能相加解释为总 CPI 损失。
  assign id_local_stall = if_id_stall && !id_ex_stall;
  assign ex_local_stall = id_ex_stall && !ex_mem_stall;
  assign mem_local_stall = ex_mem_stall && !mem_wb_stall;
  assign wb_local_stall = mem_wb_stall;

  // 这些计数器仅从 stage 接口观察“对上游形成压力”的周期。MEM 将访存
  // 保持在 EX/MEM 直到响应写入 MEM/WB，因此请求等待和响应等待都会表现为
  // EX/MEM stall；EX/MEM 握手对访存表示完成交接，不是请求接受。
  // EX 等待 FENCE.I 时不展示输出事务；对年轻指令的阻塞体现在 ID。
  // 所有 64 位计数器达到最大值后自然回绕，与 cycle/instret 的现有行为一致。

  // 计数器输出

  assign performance_o = '{
    cycle_count: stats_q.cycle_count,
    instret_count: stats_q.instret_count,
    redirect_count: stats_q.redirect_count,
    if_local_stall_cycle_count: stats_q.if_local_stall_cycle_count,
    classes: stats_q.classes,
    imem: imem_stats,
    dmem: dmem_stats
  };

  // 性能计数器更新

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      stats_q <= '0;
    end else begin
      stats_q.cycle_count <= stats_q.cycle_count + 64'd1;
      // 沿用调试提交口径，包括异常；并非排除异常的架构 minstret。
      if (retire_fire)
        stats_q.instret_count <= stats_q.instret_count + 64'd1;

      // redirect 是无背压的单周期事件。统计仲裁后实际送到 IF 的事件：EX 与
      // WB 同拍改道只计一次；包含 EX 的 FENCE.I 重取和 WB 的 trap/MRET。
      if (redirect)
        stats_q.redirect_count <= stats_q.redirect_count + 64'd1;

      if (retire_fire)
        stats_q.classes[classes_i.wb_class].instret_count <=
            stats_q.classes[classes_i.wb_class].instret_count + 64'd1;

      if (if_local_stall)
        stats_q.if_local_stall_cycle_count <=
            stats_q.if_local_stall_cycle_count + 64'd1;
      if (id_local_stall)
        stats_q.classes[classes_i.id_class].id_local_stall_cycle_count <=
            stats_q.classes[classes_i.id_class].id_local_stall_cycle_count + 64'd1;
      if (ex_local_stall)
        stats_q.classes[classes_i.ex_class].ex_local_stall_cycle_count <=
            stats_q.classes[classes_i.ex_class].ex_local_stall_cycle_count + 64'd1;
      if (mem_local_stall)
        stats_q.classes[classes_i.mem_class].mem_local_stall_cycle_count <=
            stats_q.classes[classes_i.mem_class].mem_local_stall_cycle_count + 64'd1;
      if (wb_local_stall)
        stats_q.classes[classes_i.wb_class].wb_local_stall_cycle_count <=
            stats_q.classes[classes_i.wb_class].wb_local_stall_cycle_count + 64'd1;
    end
  end

endmodule
`endif
