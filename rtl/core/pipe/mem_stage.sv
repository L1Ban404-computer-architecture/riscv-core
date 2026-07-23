// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

`include "common/assertions.svh"

module mem_stage (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic side_effect_block_i,

  // EX -> MEM 事务通道。精确异常要求 LSU 固定为单 outstanding；内部
  // fall-through 槽保存唯一一条请求元数据。
  input logic ex_mem_valid_i,
  output logic ex_mem_ready_o,
  input ex_mem_bus_t ex_mem_bus_i,

  // CoreBus 数据接口。每个 load/store 都使用同一条请求流，并按请求接受
  // 顺序获得响应；write 表示方向，size 表示访问宽度。
  output core_bus_req_t dmem_req_o,
  input core_bus_resp_t dmem_resp_i,

  // 已经发出、尚未收到响应的 load 目标。EX 只需要 valid/rd 检测
  // 未解决的 RAW 相关，不传递尚不存在的写回数据。
  output logic mem_pending_valid_o,
  output reg_addr_t mem_pending_rd_addr_o,

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

  // EX/MEM 与 MEM/WB 的公共 payload 只差 mem_req；两个 debug struct
  // 位宽和字段顺序一致，显式类型转换集中表达 stage 边界。
  function automatic mem_wb_bus_t toMemWbBus(
    wb_req_bus_t wb_req,
    exception_bus_t exception,
    commit_ctrl_bus_t commit,
    retire_meta_bus_t retire
  );
    toMemWbBus = '{
      wb_req: wb_req,
      exception: exception,
      commit: commit,
      retire: retire
    };
  endfunction

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
  // 直接由它驱动。请求握手和 outstanding 槽写入是同一个原子事件。
  assign dmem_req_o.req.addr = ex_mem_bus_i.mem_req.addr;
  assign dmem_req_o.req.write = ex_mem_bus_i.mem_req.write;
  assign dmem_req_o.req.size = ex_mem_bus_i.mem_req.size;
  assign dmem_req_o.req.wdata = ex_mem_bus_i.mem_req.write ? aligned_store_data : '0;
  assign dmem_req_o.req.wstrb = ex_mem_bus_i.mem_req.write ? store_byte_en : '0;
  // 错误响应进入 MEM/WB 后、WB 尚未提交 trap 前，不得让年轻访存借助单槽
  // 同拍 pop/push 发出请求。kill 同周期也必须关闭总线请求及级间交接。
  assign request_blocked = flush_i || side_effect_block_i ||
      (dmem_resp_i.rsp_valid && dmem_resp_i.rsp.error);
  assign dmem_req_valid = ex_mem_valid_i && memory_instruction && outstanding_ready && !request_blocked;
  assign dmem_req_o.req_valid = dmem_req_valid;
  // 单槽的 valid_i 不反向依赖 ready_o；内部的 valid_i && ready_o
  // 仍与 dmem_req_fire 完全等价，同时避免 fall-through 路径形成组合环。
  assign outstanding_input_valid = ex_mem_valid_i && memory_instruction && dmem_resp_i.req_ready &&
      !request_blocked;

  // 响应必须和槽内事务配对。MEM/WB 输入不可接受时直接反压 CoreBus
  // 响应通道，不需要额外的 response holding register。
  assign dmem_rsp_ready = outstanding_head_valid && mem_wb_input_ready;
  assign dmem_req_o.rsp_ready = dmem_rsp_ready;
  assign dmem_rsp_fire = dmem_resp_i.rsp_valid && dmem_rsp_ready;

  // 访存事务在请求被接受后释放 EX/MEM；非访存事务不能越过任何更老的
  // outstanding 访存事务，但可以在事务槽为空时进入 MEM/WB。
  always_comb begin
    if (flush_i) ex_mem_ready_o = 1'b0;
    else if (memory_instruction)
      ex_mem_ready_o = outstanding_ready && dmem_resp_i.req_ready && !request_blocked;
    else ex_mem_ready_o = !outstanding_head_valid && mem_wb_input_ready;
  end

  fall_through_register #(
    .T(ex_mem_bus_t)
  ) u_outstanding_slot (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .data_i(ex_mem_bus_i),
    .valid_i(outstanding_input_valid),
    .ready_o(outstanding_ready),
    .data_o(outstanding_head),
    .valid_o(outstanding_head_valid),
    .ready_i(dmem_rsp_fire)
  );

  assign mem_pending_valid_o = outstanding_head_valid && outstanding_head.wb_req.valid;
  assign mem_pending_rd_addr_o = outstanding_head.wb_req.rd_addr;

  load_data_unit u_load_data_unit (
    .size_i(outstanding_head.mem_req.size),
    .sign_ext_i(outstanding_head.mem_req.sign_ext),
    .addr_offset_i(outstanding_head.mem_req.addr[1:0]),
    .rdata_i(dmem_resp_i.rsp.rdata),
    .load_data_o(loaded_data)
  );

  always_comb begin
    completed_mem_bus = toMemWbBus(
      outstanding_head.wb_req,
      outstanding_head.exception,
      outstanding_head.commit,
      outstanding_head.retire
    );
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
    completed_mem_bus.retire.mem_data = outstanding_head.mem_req.write ?
        outstanding_head.retire.mem_data : loaded_data;
    if (completed_mem_bus.exception.valid)
      completed_mem_bus.retire.mem_op = RETIRE_MEM_NONE;

    bypass_mem_bus = toMemWbBus(
      ex_mem_bus_i.wb_req,
      ex_mem_bus_i.exception,
      ex_mem_bus_i.commit,
      ex_mem_bus_i.retire
    );

    // outstanding 响应优先；事务槽非空时 ex_mem_ready_o 会阻止非访存输入。
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
    .flush_i,
    .valid_i(mem_wb_input_valid && !flush_i),
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

  // verilog_format: off
  `ASSERT_STABLE(
    DmemReqStable,
    dmem_req_o.req_valid,
    dmem_resp_i.req_ready,
    dmem_req_o.req,
    core_bus_req_chan_t'(0),
    clk_i,
    !rst_ni || flush_i,
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
