// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 核心性能统计。
//
// 统计分类退休数、局部背压前沿和 CoreBus 事务性能。
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
  // 临时单指令限制：仅在前端负责推进当前指令时统计供给不足。
  input logic if_local_stall_enable_i,

  // 存储器监视
  core_bus_if.monitor imem,
  core_bus_if.monitor dmem,

  // 性能观测
  performance_debug_if.producer performance
);

  ////////////////////////
  // 内部事件与计数状态 //
  ////////////////////////

  logic mem_wb_fire;

  logic if_id_stall;
  logic id_ex_stall;
  logic ex_mem_stall;
  logic mem_wb_stall;

  logic if_local_stall;
  logic id_local_stall;
  logic ex_local_stall;
  logic mem_local_stall;
  logic wb_local_stall;

  perf_class_e id_class, ex_class, mem_class, wb_class;

  performance_debug_payload_t performance_debug_q;
  memory_performance_payload_t imem_stats, dmem_stats;

  ////////////////////////
  // 观察器内部指令分类 //
  ////////////////////////

  // 只按主 opcode 分组，不重复检查 funct3/funct7 合法性。
  // 取指访问错误没有可信指令；后续执行/访存异常仍按原 opcode 分类。
  function automatic perf_class_e classify_opcode(
    input logic [6:0] opcode,
    input logic fetch_access_fault
  );
    if (fetch_access_fault) return PERF_OTHER;
    case (opcode)
      OPC_OP, OPC_OP_IMM, OPC_LUI, OPC_AUIPC: return PERF_COMPUTE;
      OPC_LOAD: return PERF_LOAD;
      OPC_STORE: return PERF_STORE;
      OPC_BRANCH: return PERF_BRANCH;
      OPC_JAL, OPC_JALR: return PERF_JUMP;
      OPC_SYSTEM, OPC_MISC_MEM: return PERF_SYSTEM;
      default: return PERF_OTHER;
    endcase
  endfunction

  // 分类使用各级入口当前指令，完全由 monitor payload 提供。
  assign id_class = classify_opcode(if_id.payload.meta.instr[6:0],
      if_id.payload.exception.valid && if_id.payload.exception.cause == EXC_INST_ACCESS_FAULT);
  assign ex_class = classify_opcode(id_ex.payload.meta.instr[6:0],
      id_ex.payload.exception.valid && id_ex.payload.exception.cause == EXC_INST_ACCESS_FAULT);
  assign mem_class = classify_opcode(ex_mem.payload.commit_ctx.meta.instr[6:0],
      ex_mem.payload.commit_ctx.exception.valid &&
      ex_mem.payload.commit_ctx.exception.cause == EXC_INST_ACCESS_FAULT);
  assign wb_class = classify_opcode(mem_wb.payload.meta.instr[6:0],
      mem_wb.payload.exception.valid && mem_wb.payload.exception.cause == EXC_INST_ACCESS_FAULT);

  ////////////////
  // 计数器输出 //
  ////////////////

  always_comb begin
    performance.payload = performance_debug_q;
    performance.payload.imem = imem_stats;
    performance.payload.dmem = dmem_stats;
  end

  memory_performance_stats u_imem_stats (
    .clk_i, .rst_ni,
    .cycle_i(performance_debug_q.cycle_count),
    .bus(imem),
    .stats_o(imem_stats)
  );
  memory_performance_stats u_dmem_stats (
    .clk_i, .rst_ni,
    .cycle_i(performance_debug_q.cycle_count),
    .bus(dmem),
    .stats_o(dmem_stats)
  );

  //////////////////////////////
  // 传输、阻塞与局部背压事件 //
  //////////////////////////////

  // fire 只表示边界上真实发生的事务传输。它不使用 flush 额外门控：stage 已经
  // 按功能语义决定当拍 valid/ready，统计侧必须保留 trap/MRET 退休等真实握手。
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
  // 临时单指令限制：后端执行期间的主动停取由使能排除；cycle_count 仍累计。
  assign if_local_stall = if_local_stall_enable_i && if_id.ready && !if_id.valid && !redirect.valid;

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
  // 所有 64 位计数器达到最大值后自然回绕，与 cycle/instret 的现有行为一致。

  ////////////////////
  // 性能计数器更新 //
  ////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      performance_debug_q <= '0;
    end else begin
      performance_debug_q.cycle_count <= performance_debug_q.cycle_count + 64'd1;
      // 沿用调试提交口径，包括异常；并非排除异常的架构 minstret。
      if (mem_wb_fire)
        performance_debug_q.instret_count <= performance_debug_q.instret_count + 64'd1;

      if (mem_wb_fire)
        performance_debug_q.classes[wb_class].instret_count <=
            performance_debug_q.classes[wb_class].instret_count + 64'd1;

      if (if_local_stall)
        performance_debug_q.if_local_stall_cycle_count <=
            performance_debug_q.if_local_stall_cycle_count + 64'd1;
      if (id_local_stall)
        performance_debug_q.classes[id_class].id_local_stall_cycle_count <=
            performance_debug_q.classes[id_class].id_local_stall_cycle_count + 64'd1;
      if (ex_local_stall)
        performance_debug_q.classes[ex_class].ex_local_stall_cycle_count <=
            performance_debug_q.classes[ex_class].ex_local_stall_cycle_count + 64'd1;
      if (mem_local_stall)
        performance_debug_q.classes[mem_class].mem_local_stall_cycle_count <=
            performance_debug_q.classes[mem_class].mem_local_stall_cycle_count + 64'd1;
      if (wb_local_stall)
        performance_debug_q.classes[wb_class].wb_local_stall_cycle_count <=
            performance_debug_q.classes[wb_class].wb_local_stall_cycle_count + 64'd1;
    end
  end

endmodule
