// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "common/assertions.svh"

// 数据访存级。
//
// 将处理器 load/store 语义转换为 CoreBus 请求，完成写数据对齐、读数据扩展
// 和总线错误归并，并形成 MEM/WB 事务。
// 最多存在一笔未完成访存；请求元数据必须保存至响应返回；年轻副作用不得越过
// 待提交异常或串行化事务；总线错误必须随原指令精确提交。
module mem_stage
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
  import riscv_core_pkg::*;
(
  // 全局控制
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic side_effect_block_i,

  // 流水事务
  ex_mem_if.consumer ex_mem,
  core_bus_if.master dmem,
  mem_pending_if.producer mem_pending,
  writeback_if.producer mem_wb_forward,
  mem_wb_if.producer mem_wb,

  // 状态指示
  output logic busy_o
);

  ////////////////////////
  // 私有类型与内部信号 //
  ////////////////////////

  word_t aligned_store_data;
  byte_en_t store_byte_en;
  word_t loaded_data;

  ex_mem_payload_t ex_mem_payload;
  ex_mem_payload_t outstanding_head;
  logic outstanding_ready;
  logic outstanding_head_valid;

  logic memory_instruction;
  logic outstanding_input_valid;
  logic dmem_req_valid;
  logic dmem_rsp_ready;
  logic dmem_rsp_fire;
  logic request_blocked;

  mem_wb_payload_t mem_wb_payload;
  mem_wb_payload_t completed_mem_bus;
  mem_wb_payload_t bypass_mem_bus;
  mem_wb_payload_t mem_wb_input_bus;
  logic mem_wb_input_valid;
  logic mem_wb_input_ready;

  ////////////////////////
  // 流水接口解包与打包 //
  ////////////////////////

  assign ex_mem_payload = ex_mem.payload;
  assign mem_wb.payload = mem_wb_payload;

  ////////////////////////
  // 事务转换与数据整理 //
  ////////////////////////

  // EX/MEM 与 MEM/WB 的公共 payload 只差 mem_req；显式构造集中表达
  // 功能 PC、提交事务和只写调试 payload 的 stage 边界。
  function automatic mem_wb_payload_t toMemWbBus(
    pc_t pc,
    writeback_payload_t wb_req,
    exception_payload_t exception,
    commit_ctrl_payload_t commit,
    retire_debug_payload_t debug
  );
    toMemWbBus = '{
      pc: pc,
      wb_req: wb_req,
      exception: exception,
      commit: commit,
      debug: debug
    };
  endfunction

  // 这里是核心访存语义与 CoreBus ABI 的唯一宽度转换边界。两侧枚举目前编码一致，
  // 仍逐项映射以避免未来任一侧扩展时形成未经审查的隐式协议变化。
  function automatic core_bus_size_e toCoreBusSize(input mem_size_e size);
    unique case (size)
      MEM_SIZE_BYTE: return CORE_BUS_SIZE_BYTE;
      MEM_SIZE_HALF: return CORE_BUS_SIZE_HALF;
      MEM_SIZE_WORD: return CORE_BUS_SIZE_WORD;
      default: return CORE_BUS_SIZE_WORD;
    endcase
  endfunction

  // Store lane 对齐和 load lane 提取是独立的组合数据单元。请求端可能处理
  // 年轻 store，同时响应端处理另一条更老 load，因此两套元数据不能共用。
  store_data_unit u_store_data_unit (
    .size_i(ex_mem_payload.mem_req.size),
    .addr_offset_i(ex_mem_payload.mem_req.addr[1:0]),
    .wdata_i(ex_mem_payload.mem_req.wdata),
    .aligned_wdata_o(aligned_store_data),
    .wstrb_o(store_byte_en)
  );

  assign memory_instruction = ex_mem_payload.mem_req.valid;

  // EX/MEM 本身已经满足严格 ready/valid 保持规则，因此 CoreBus 请求可以
  // 直接由它驱动。请求握手和 outstanding 槽写入是同一个原子事件。
  assign dmem.addr = ex_mem_payload.mem_req.addr;
  assign dmem.write = ex_mem_payload.mem_req.write;
  assign dmem.size = toCoreBusSize(ex_mem_payload.mem_req.size);
  assign dmem.wdata = ex_mem_payload.mem_req.write ? aligned_store_data : '0;
  assign dmem.wstrb = ex_mem_payload.mem_req.write ? store_byte_en : '0;
  // 错误响应进入 MEM/WB 后、WB 尚未提交 trap 前，不得让年轻访存借助单槽
  // 同拍 pop/push 发出请求。kill 同周期也必须关闭总线请求及级间交接。
  assign request_blocked = flush_i || side_effect_block_i ||
      (dmem.rsp_valid && dmem.error);
  assign dmem_req_valid = ex_mem.valid && memory_instruction && outstanding_ready && !request_blocked;
  assign dmem.req_valid = dmem_req_valid;
  // 单槽的 valid_i 不反向依赖 ready_o；内部的 valid_i && ready_o
  // 仍与 dmem_req_fire 完全等价，同时避免 fall-through 路径形成组合环。
  assign outstanding_input_valid = ex_mem.valid && memory_instruction && dmem.req_ready &&
      !request_blocked;

  // 响应必须和槽内事务配对。MEM/WB 输入不可接受时直接反压 CoreBus
  // 响应通道，不需要额外的 response holding register。
  assign dmem_rsp_ready = outstanding_head_valid && mem_wb_input_ready;
  assign dmem.rsp_ready = dmem_rsp_ready;
  assign dmem_rsp_fire = dmem.rsp_valid && dmem_rsp_ready;

  // 访存事务在请求被接受后释放 EX/MEM；非访存事务不能越过任何更老的
  // outstanding 访存事务，但可以在事务槽为空时进入 MEM/WB。
  always_comb begin
    if (flush_i) ex_mem.ready = 1'b0;
    else if (memory_instruction)
      ex_mem.ready = outstanding_ready && dmem.req_ready && !request_blocked;
    else ex_mem.ready = !outstanding_head_valid && mem_wb_input_ready;
  end

  fall_through_register #(
    .T(ex_mem_payload_t)
  ) u_outstanding_slot (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .data_i(ex_mem_payload),
    .valid_i(outstanding_input_valid),
    .ready_o(outstanding_ready),
    .data_o(outstanding_head),
    .valid_o(outstanding_head_valid),
    .ready_i(dmem_rsp_fire)
  );

  assign mem_pending.valid = outstanding_head_valid && outstanding_head.wb_req.valid;
  assign mem_pending.rd_addr = outstanding_head.wb_req.rd_addr;

  load_data_unit u_load_data_unit (
    .size_i(outstanding_head.mem_req.size),
    .sign_ext_i(outstanding_head.mem_req.sign_ext),
    .addr_offset_i(outstanding_head.mem_req.addr[1:0]),
    .rdata_i(dmem.rdata),
    .load_data_o(loaded_data)
  );

  //////////////////////////////////////
  // 访存完成、异常归并与 MEM/WB 仲裁 //
  //////////////////////////////////////

  always_comb begin
    completed_mem_bus = toMemWbBus(
      outstanding_head.pc,
      outstanding_head.wb_req,
      outstanding_head.exception,
      outstanding_head.commit,
      outstanding_head.debug
    );
    if (!completed_mem_bus.exception.valid && dmem.error) begin
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
    completed_mem_bus.debug.mem_data = outstanding_head.mem_req.write ?
        outstanding_head.mem_req.wdata : loaded_data;
    completed_mem_bus.debug.gpr_we =
        completed_mem_bus.wb_req.valid && completed_mem_bus.wb_req.data_valid;
    completed_mem_bus.debug.gpr_waddr = completed_mem_bus.wb_req.rd_addr;
    completed_mem_bus.debug.gpr_wdata = completed_mem_bus.wb_req.wdata;
    if (completed_mem_bus.exception.valid) begin
      completed_mem_bus.debug.mem_op = RETIRE_MEM_NONE;
      completed_mem_bus.debug.gpr_we = 1'b0;
      completed_mem_bus.debug.gpr_waddr = '0;
      completed_mem_bus.debug.gpr_wdata = '0;
    end

    bypass_mem_bus = toMemWbBus(
      ex_mem_payload.pc,
      ex_mem_payload.wb_req,
      ex_mem_payload.exception,
      ex_mem_payload.commit,
      ex_mem_payload.debug
    );

    // outstanding 响应优先；事务槽非空时 ex_mem.ready 会阻止非访存输入。
    if (outstanding_head_valid) begin
      mem_wb_input_valid = dmem.rsp_valid;
      mem_wb_input_bus = completed_mem_bus;
    end else begin
      mem_wb_input_valid = ex_mem.valid && !memory_instruction;
      mem_wb_input_bus = bypass_mem_bus;
    end
  end

  /////////////////////////////
  // MEM/WB 弹性寄存器与前递 //
  /////////////////////////////

  stream_register #(
    .T(mem_wb_payload_t)
  ) u_mem_wb_register (
    .clk_i,
    .rst_ni,
    .flush_i,
    .valid_i(mem_wb_input_valid && !flush_i),
    .ready_o(mem_wb_input_ready),
    .data_i(mem_wb_input_bus),
    .valid_o(mem_wb.valid),
    .ready_i(mem_wb.ready),
    .data_o(mem_wb_payload)
  );

  assign mem_wb_forward.valid =
      mem_wb.valid && mem_wb_payload.wb_req.valid;
  assign mem_wb_forward.data_valid = mem_wb_payload.wb_req.data_valid;
  assign mem_wb_forward.rd_addr = mem_wb_payload.wb_req.rd_addr;
  assign mem_wb_forward.wdata = mem_wb_payload.wb_req.wdata;

  assign busy_o = outstanding_head_valid;

  //////////////
  // 协议断言 //
  //////////////

  // verilog_format: off
  `ASSERT_STABLE(
    DmemReqStable,
    dmem.req_valid,
    dmem.req_ready,
    {dmem.addr, dmem.write, dmem.size, dmem.wdata, dmem.wstrb},
    '0,
    clk_i,
    !rst_ni || flush_i,
    "CoreBus data request must remain stable while waiting for ready."
  )

  `ASSERT(
    DmemReqValidStable,
    dmem.req_valid && !dmem.req_ready |=> dmem.req_valid,
    clk_i,
    !rst_ni,
    "CoreBus data request valid must remain asserted until ready."
  )

  `ASSERT_STABLE(
    MemWbStable,
    mem_wb.valid,
    mem_wb.ready,
    mem_wb_payload,
    mem_wb_payload_t'(0),
    clk_i,
    !rst_ni,
    "MEM/WB payload must remain stable while valid is waiting for ready."
  )
  // verilog_format: on

endmodule
