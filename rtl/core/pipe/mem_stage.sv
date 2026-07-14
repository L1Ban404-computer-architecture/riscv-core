// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

`include "common/assertions.svh"

module mem_stage #(
  parameter int unsigned MemOutstandingDepth = 2
) (
  input logic clk_i,
  input logic rst_ni,
  input logic kill_i,
  input logic side_effect_block_i,

  // EX -> MEM 事务通道。首版精确异常将 LSU 限制为单 outstanding；内部 FIFO
  // 仍统一保存请求元数据，以便请求响应解耦并保留未来扩展接口。
  input logic ex_mem_valid_i,
  output logic ex_mem_ready_o,
  input ex_mem_bus_t ex_mem_bus_i,

  // CoreBus 数据接口。每个 load/store 都使用同一条请求流，并按请求接受
  // 顺序获得响应；wstrb=0 表示读，非 0 表示写。
  output core_bus_req_t dmem_req_o,
  input core_bus_resp_t dmem_resp_i,

  // 已经发出、尚未收到响应的 load 写回候选。当前数组只有一个有效槽位；
  // data_valid 恒为 0，EX 用它检测未解决的 RAW 相关。
  output wb_req_bus_t mem_pending_wb_req_o[MemOutstandingDepth],

  // MEM/WB 输出寄存器中的写回候选，用于已完成数据的前递。
  output wb_req_bus_t mem_wb_req_o,

  // MEM -> WB 事务通道。MEM debug 会记录访存请求和响应行为。
  output logic mem_wb_valid_o,
  input logic mem_wb_ready_i,
  output mem_wb_bus_t mem_wb_bus_o,
  output logic busy_o
);

  word_t aligned_store_data;
  byte_en_t store_byte_en;
  word_t loaded_data;

  ex_mem_bus_t outstanding_head;
  ex_mem_bus_t outstanding_entries[MemOutstandingDepth];
  logic [MemOutstandingDepth-1:0] outstanding_valid;
  logic outstanding_ready;
  logic outstanding_head_valid;

  logic memory_instruction;
  logic outstanding_input_valid;
  logic dmem_req_valid;
  logic dmem_rsp_ready;
  logic dmem_rsp_fire;
  logic request_blocked;

  mem_wb_bus_t completed_mem_bus;
  mem_wb_bus_t bypass_mem_bus;
  mem_wb_bus_t mem_wb_input_bus;
  logic mem_wb_input_valid;
  logic mem_wb_input_ready;

  // Store lane 对齐和 load lane 提取是独立的组合数据单元。请求端可能处理
  // 年轻 store，同时响应端处理另一条更老 load，因此两套元数据不能共用。
  store_data_unit u_store_data_unit (
    .size_i(ex_mem_bus_i.mem_req.size),
    .addr_offset_i(ex_mem_bus_i.mem_req.addr[1:0]),
    .wdata_i(ex_mem_bus_i.mem_req.wdata),
    .aligned_wdata_o(aligned_store_data),
    .wstrb_o(store_byte_en)
  );

  assign memory_instruction = ex_mem_bus_i.mem_req.valid;

  // EX/MEM 本身已经满足严格 ready/valid 保持规则，因此 CoreBus 请求可以
  // 直接由它驱动。请求握手和 outstanding FIFO push 是同一个原子事件。
  assign dmem_req_o.req.addr = {ex_mem_bus_i.mem_req.addr[XLen-1:2], 2'b00};
  assign dmem_req_o.req.wdata = ex_mem_bus_i.mem_req.write ? aligned_store_data : '0;
  assign dmem_req_o.req.wstrb = ex_mem_bus_i.mem_req.write ? store_byte_en : '0;
  // 错误响应进入 MEM/WB 后、WB 尚未提交 trap 前，不得让年轻访存借助 FIFO
  // 同拍 pop/push 发出请求。kill 同周期也必须关闭总线请求及级间交接。
  assign request_blocked = kill_i || side_effect_block_i ||
      (dmem_resp_i.rsp_valid && dmem_resp_i.rsp.error);
  assign dmem_req_valid = ex_mem_valid_i && memory_instruction && outstanding_ready && !request_blocked;
  assign dmem_req_o.req_valid = dmem_req_valid;
  // FIFO 的 valid_i 不反向依赖 ready_o；FIFO 内部的 valid_i && ready_o
  // 仍与 dmem_req_fire 完全等价，同时避免 fall-through 路径形成组合环。
  assign outstanding_input_valid = ex_mem_valid_i && memory_instruction && dmem_resp_i.req_ready &&
      !request_blocked;

  // 响应必须和 FIFO 头部事务配对。MEM/WB 输入不可接受时直接反压 CoreBus
  // 响应通道，不需要额外的 response holding register。
  assign dmem_rsp_ready = outstanding_head_valid && mem_wb_input_ready;
  assign dmem_req_o.rsp_ready = dmem_rsp_ready;
  assign dmem_rsp_fire = dmem_resp_i.rsp_valid && dmem_rsp_ready;

  // 访存事务在请求被接受后释放 EX/MEM；非访存事务不能越过任何更老的
  // outstanding 访存事务，但可以在 FIFO 为空时进入 MEM/WB。
  always_comb begin
    if (kill_i) ex_mem_ready_o = 1'b0;
    else if (memory_instruction)
      ex_mem_ready_o = outstanding_ready && dmem_resp_i.req_ready && !request_blocked;
    else ex_mem_ready_o = !outstanding_head_valid && mem_wb_input_ready;
  end

  peek_fifo #(
    .Depth(MemOutstandingDepth),
    .FallThrough(1'b1),
    .SameCycleRW(1'b1),
    .T(ex_mem_bus_t)
  ) u_outstanding_fifo (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .usage_o(  /* unused */),
    .data_i(ex_mem_bus_i),
    .valid_i(outstanding_input_valid),
    .ready_o(outstanding_ready),
    .data_o(outstanding_head),
    .valid_o(outstanding_head_valid),
    .ready_i(dmem_rsp_fire),
    .data_all_o(outstanding_entries),
    .valid_all_o(outstanding_valid)
  );

  // 全条目输出只表达尚未解决的 load 目标寄存器。常量 data_valid/wdata
  // 使 forwarding unit 只综合比较器和 stall 归约逻辑。
  always_comb begin
    for (int unsigned i = 0; i < MemOutstandingDepth; i++) begin
      mem_pending_wb_req_o[i] = outstanding_entries[i].wb_req;
      mem_pending_wb_req_o[i].valid = outstanding_valid[i] && outstanding_entries[i].wb_req.valid;
      mem_pending_wb_req_o[i].data_valid = 1'b0;
      mem_pending_wb_req_o[i].wdata = '0;
    end
  end

  load_data_unit u_load_data_unit (
    .size_i(outstanding_head.mem_req.size),
    .sign_ext_i(outstanding_head.mem_req.sign_ext),
    .addr_offset_i(outstanding_head.mem_req.addr[1:0]),
    .rdata_i(dmem_resp_i.rsp.rdata),
    .load_data_o(loaded_data)
  );

  always_comb begin
    completed_mem_bus = '0;
    completed_mem_bus.wb_req = outstanding_head.wb_req;
    completed_mem_bus.exception = outstanding_head.exception;
    completed_mem_bus.commit = outstanding_head.commit;
    if (!completed_mem_bus.exception.valid && dmem_resp_i.rsp.error) begin
      completed_mem_bus.exception.valid = 1'b1;
      completed_mem_bus.exception.cause = outstanding_head.mem_req.write ?
          EXC_STORE_ACCESS_FAULT : EXC_LOAD_ACCESS_FAULT;
      completed_mem_bus.exception.tval = outstanding_head.mem_req.addr;
    end
    if (outstanding_head.wb_req.valid && !completed_mem_bus.exception.valid) begin
      completed_mem_bus.wb_req.data_valid = 1'b1;
      completed_mem_bus.wb_req.wdata = loaded_data;
    end else if (completed_mem_bus.exception.valid) begin
      completed_mem_bus.wb_req = '0;
    end
    completed_mem_bus.debug.pc = outstanding_head.debug.pc;
    completed_mem_bus.debug.instr = outstanding_head.debug.instr;
    completed_mem_bus.debug.mem_valid = outstanding_head.debug.mem_valid;
    completed_mem_bus.debug.mem_write = outstanding_head.debug.mem_write;
    completed_mem_bus.debug.mem_size = outstanding_head.debug.mem_size;
    completed_mem_bus.debug.mem_addr = outstanding_head.debug.mem_addr;
    completed_mem_bus.debug.mem_wdata = outstanding_head.debug.mem_wdata;
    completed_mem_bus.debug.redirect_valid = outstanding_head.debug.redirect_valid;
    completed_mem_bus.debug.redirect_target_pc = outstanding_head.debug.redirect_target_pc;
    if (completed_mem_bus.exception.valid) completed_mem_bus.debug.mem_valid = 1'b0;

    bypass_mem_bus = '0;
    bypass_mem_bus.wb_req = ex_mem_bus_i.wb_req;
    bypass_mem_bus.exception = ex_mem_bus_i.exception;
    bypass_mem_bus.commit = ex_mem_bus_i.commit;
    bypass_mem_bus.debug.pc = ex_mem_bus_i.debug.pc;
    bypass_mem_bus.debug.instr = ex_mem_bus_i.debug.instr;
    bypass_mem_bus.debug.mem_valid = ex_mem_bus_i.debug.mem_valid;
    bypass_mem_bus.debug.mem_write = ex_mem_bus_i.debug.mem_write;
    bypass_mem_bus.debug.mem_size = ex_mem_bus_i.debug.mem_size;
    bypass_mem_bus.debug.mem_addr = ex_mem_bus_i.debug.mem_addr;
    bypass_mem_bus.debug.mem_wdata = ex_mem_bus_i.debug.mem_wdata;
    bypass_mem_bus.debug.redirect_valid = ex_mem_bus_i.debug.redirect_valid;
    bypass_mem_bus.debug.redirect_target_pc = ex_mem_bus_i.debug.redirect_target_pc;

    // outstanding 响应优先；FIFO 非空时 ex_mem_ready_o 会阻止非访存输入。
    if (outstanding_head_valid) begin
      mem_wb_input_valid = dmem_resp_i.rsp_valid;
      mem_wb_input_bus = completed_mem_bus;
    end else begin
      mem_wb_input_valid = ex_mem_valid_i && !memory_instruction;
      mem_wb_input_bus = bypass_mem_bus;
    end
  end

  stream_register #(
    .T(mem_wb_bus_t)
  ) u_mem_wb_register (
    .clk_i,
    .rst_ni,
    .clr_i(kill_i),
    .valid_i(mem_wb_input_valid && !kill_i),
    .ready_o(mem_wb_input_ready),
    .data_i(mem_wb_input_bus),
    .valid_o(mem_wb_valid_o),
    .ready_i(mem_wb_ready_i),
    .data_o(mem_wb_bus_o)
  );

  always_comb begin
    mem_wb_req_o = mem_wb_bus_o.wb_req;
    mem_wb_req_o.valid = mem_wb_valid_o && mem_wb_bus_o.wb_req.valid;
  end

  assign busy_o = outstanding_head_valid;

  // 多 outstanding store 无法在当前 CoreBus 上撤销；恢复更深队列前必须先引入
  // 提交式 store buffer。因此暂时在 elaboration 阶段拒绝其它配置。
  `ASSERT_INIT(MemOutstandingDepthIsOne, MemOutstandingDepth == 1,
               "Precise exceptions currently require MemOutstandingDepth=1.")

  // verilog_format: off
  `ASSERT_STABLE(
    DmemReqStable,
    dmem_req_o.req_valid,
    dmem_resp_i.req_ready,
    dmem_req_o.req,
    core_bus_req_chan_t'(0),
    clk_i,
    !rst_ni || kill_i,
    "CoreBus data request must remain stable while waiting for ready."
  )

  `ASSERT(
    DmemReqValidStable,
    dmem_req_o.req_valid && !dmem_resp_i.req_ready |=> dmem_req_o.req_valid,
    clk_i,
    !rst_ni,
    "CoreBus data request valid must remain asserted until ready."
  )

  `ASSERT_STABLE(
    MemWbStable,
    mem_wb_valid_o,
    mem_wb_ready_i,
    mem_wb_bus_o,
    mem_wb_bus_t'(0),
    clk_i,
    !rst_ni,
    "MEM/WB payload must remain stable while valid is waiting for ready."
  )
  // verilog_format: on

endmodule
