// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 核心性能统计。
//
// 统计流水边界传输、边界阻塞、取指供给不足和局部背压前沿的累计周期数。
// 仅观察公开 ready/valid 与全局控制，不读取流水级私有状态；计数不参与功能
// 控制；各局部阻塞计数允许重叠，不能直接相加解释为总 CPI 损失。
module performance_stats
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 流水监视
  if_id_if.monitor if_id,
  id_ex_if.monitor id_ex,
  ex_mem_if.monitor ex_mem,
  mem_wb_if.monitor mem_wb,
  redirect_if.monitor redirect,
  input logic flush_backend_i,

  // 性能观测
  performance_debug_if.producer performance
);

  ////////////////////////
  // 内部事件与计数状态 //
  ////////////////////////

  logic if_id_fire;
  logic id_ex_fire;
  logic ex_mem_fire;
  logic mem_wb_fire;

  logic if_id_stall;
  logic id_ex_stall;
  logic ex_mem_stall;
  logic mem_wb_stall;

  logic if_starve;
  logic id_local_stall;
  logic ex_local_stall;
  logic mem_local_stall;
  logic wb_local_stall;

  performance_debug_payload_t performance_debug_q;

  ////////////////
  // 计数器输出 //
  ////////////////

  assign performance.cycle_count = performance_debug_q.cycle_count;
  assign performance.instret_count = performance_debug_q.instret_count;
  assign performance.if_id_fire_count = performance_debug_q.if_id_fire_count;
  assign performance.id_ex_fire_count = performance_debug_q.id_ex_fire_count;
  assign performance.ex_mem_fire_count = performance_debug_q.ex_mem_fire_count;
  assign performance.mem_wb_fire_count = performance_debug_q.mem_wb_fire_count;
  assign performance.if_id_stall_cycle_count =
      performance_debug_q.if_id_stall_cycle_count;
  assign performance.id_ex_stall_cycle_count =
      performance_debug_q.id_ex_stall_cycle_count;
  assign performance.ex_mem_stall_cycle_count =
      performance_debug_q.ex_mem_stall_cycle_count;
  assign performance.mem_wb_stall_cycle_count =
      performance_debug_q.mem_wb_stall_cycle_count;
  assign performance.if_starve_cycle_count =
      performance_debug_q.if_starve_cycle_count;
  assign performance.id_local_stall_cycle_count =
      performance_debug_q.id_local_stall_cycle_count;
  assign performance.ex_local_stall_cycle_count =
      performance_debug_q.ex_local_stall_cycle_count;
  assign performance.mem_local_stall_cycle_count =
      performance_debug_q.mem_local_stall_cycle_count;
  assign performance.wb_local_stall_cycle_count =
      performance_debug_q.wb_local_stall_cycle_count;

  //////////////////////////////
  // 传输、阻塞与局部背压事件 //
  //////////////////////////////

  // fire 只表示边界上真实发生的事务传输。它不使用 flush 额外门控：stage 已经
  // 按功能语义决定当拍 valid/ready，统计侧必须保留 trap/MRET 退休等真实握手。
  assign if_id_fire = if_id.valid && if_id.ready;
  assign id_ex_fire = id_ex.valid && id_ex.ready;
  assign ex_mem_fire = ex_mem.valid && ex_mem.ready;
  assign mem_wb_fire = mem_wb.valid && mem_wb.ready;

  // 原始 stall 表示边界上存在事务需求但接收端不能接受。redirect 或后端 flush
  // 会主动屏蔽 valid/ready 并清除错误路径事务，这种协议行为不是性能阻塞，因而
  // 在对应冲刷当拍从 stall 统计中排除。
  assign if_id_stall = if_id.valid && !if_id.ready && !redirect.valid;
  assign id_ex_stall = id_ex.valid && !id_ex.ready && !flush_backend_i;
  assign ex_mem_stall = ex_mem.valid && !ex_mem.ready && !flush_backend_i;
  assign mem_wb_stall = mem_wb.valid && !mem_wb.ready && !flush_backend_i;

  // IF 没有 core 内部的输入握手，因此不能按其他 stage 的入口阻塞方式统计。
  // 这里把“后端愿意接收而 IF/ID 没有事务”定义为 IF 供给不足；redirect 当拍
  // 不计入，但 redirect 后恢复取指导致的空泡仍会自然计入。
  assign if_starve = if_id.ready && !if_id.valid && !redirect.valid;

  // 局部阻塞前沿用于剔除逐级向上传播的背压。某阶段阻挡了入口，而它的出口
  // 边界没有同时阻塞，说明这条背压链在该阶段开始。非相邻阶段可在同一周期
  // 各自形成独立前沿，所以这些计数器允许重叠，不能相加解释为总 CPI 损失。
  assign id_local_stall = if_id_stall && !id_ex_stall;
  assign ex_local_stall = id_ex_stall && !ex_mem_stall;
  assign mem_local_stall = ex_mem_stall && !mem_wb_stall;
  assign wb_local_stall = mem_wb_stall;

  // 这些计数器仅从 stage 接口观察“对上游形成压力”的周期。例如 MEM 已经接受
  // 请求、正在等待响应，但此时没有年轻事务停在 EX/MEM，接口上不会出现 stall，
  // 因而不能把这种内部等待归因给 MEM。若未来需要完整 CPI 分解，应另行引入
  // stage 内部原因事件，而不能改变本组接口级计数器的既定语义。
  // 所有 64 位计数器达到最大值后自然回绕，与 cycle/instret 的现有行为一致。

  ////////////////////
  // 性能计数器更新 //
  ////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      performance_debug_q <= '0;
    end else begin
      performance_debug_q.cycle_count <= performance_debug_q.cycle_count + 64'd1;
      if (mem_wb_fire)
        performance_debug_q.instret_count <= performance_debug_q.instret_count + 64'd1;

      if (if_id_fire)
        performance_debug_q.if_id_fire_count <= performance_debug_q.if_id_fire_count + 64'd1;
      if (id_ex_fire)
        performance_debug_q.id_ex_fire_count <= performance_debug_q.id_ex_fire_count + 64'd1;
      if (ex_mem_fire)
        performance_debug_q.ex_mem_fire_count <= performance_debug_q.ex_mem_fire_count + 64'd1;
      if (mem_wb_fire)
        performance_debug_q.mem_wb_fire_count <= performance_debug_q.mem_wb_fire_count + 64'd1;

      if (if_id_stall)
        performance_debug_q.if_id_stall_cycle_count <=
            performance_debug_q.if_id_stall_cycle_count + 64'd1;
      if (id_ex_stall)
        performance_debug_q.id_ex_stall_cycle_count <=
            performance_debug_q.id_ex_stall_cycle_count + 64'd1;
      if (ex_mem_stall)
        performance_debug_q.ex_mem_stall_cycle_count <=
            performance_debug_q.ex_mem_stall_cycle_count + 64'd1;
      if (mem_wb_stall)
        performance_debug_q.mem_wb_stall_cycle_count <=
            performance_debug_q.mem_wb_stall_cycle_count + 64'd1;

      if (if_starve)
        performance_debug_q.if_starve_cycle_count <=
            performance_debug_q.if_starve_cycle_count + 64'd1;
      if (id_local_stall)
        performance_debug_q.id_local_stall_cycle_count <=
            performance_debug_q.id_local_stall_cycle_count + 64'd1;
      if (ex_local_stall)
        performance_debug_q.ex_local_stall_cycle_count <=
            performance_debug_q.ex_local_stall_cycle_count + 64'd1;
      if (mem_local_stall)
        performance_debug_q.mem_local_stall_cycle_count <=
            performance_debug_q.mem_local_stall_cycle_count + 64'd1;
      if (wb_local_stall)
        performance_debug_q.wb_local_stall_cycle_count <=
            performance_debug_q.wb_local_stall_cycle_count + 64'd1;
    end
  end

endmodule
