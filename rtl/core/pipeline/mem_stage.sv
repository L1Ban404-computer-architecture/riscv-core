// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 对齐访存数据，发出 CoreBus 请求，归并响应及异常后交给 MEM/WB。
// EX/MEM 保留元数据直到响应握手；最多一笔在途，年轻访存不得越过提交屏障。
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
  mem_wb_if.producer result
`ifndef SYNTHESIS
  , output riscv_debug_pkg::memory_debug_payload_t debug_o
`endif
);

  word_t aligned_store_data;
  word_t loaded_data;

  logic inflight_q;

  logic memory_instruction;
  logic request_blocked;

  mem_wb_payload_t next_payload;

  // 事务转换与数据整理

  // 核心访存宽度与 CoreBus size 的唯一转换边界。
  function automatic core_bus_size_e to_core_bus_size(input mem_size_e size);
    unique case (size)
      MEM_SIZE_BYTE: return CORE_BUS_SIZE_BYTE;
      MEM_SIZE_HALF: return CORE_BUS_SIZE_HALF;
      MEM_SIZE_WORD: return CORE_BUS_SIZE_WORD;
      default: return CORE_BUS_SIZE_WORD;
    endcase
  endfunction

  // 请求和响应共用 EX/MEM 中保持至响应握手的元数据。
  store_data_unit u_store_data_unit (
    .size_i(ex_mem.payload.mem_req.size),
    .addr_offset_i(ex_mem.payload.mem_req.addr[1:0]),
    .wdata_i(ex_mem.payload.mem_req.wdata),
    .aligned_wdata_o(aligned_store_data)
  );

  assign memory_instruction = ex_mem.payload.mem_req.valid;

  // EX/MEM 本身已经满足严格 ready/valid 保持规则，因此 CoreBus 请求可以
  // 直接由它驱动；请求握手后仍保持背压，直到响应进入 MEM/WB。
  // CoreBus 携带 write/size；写字节掩码由下游适配器按 size 与地址低位推导。
  assign dmem.req_payload.addr = ex_mem.payload.mem_req.addr;
  assign dmem.req_payload.write = ex_mem.payload.mem_req.write;
  assign dmem.req_payload.size = to_core_bus_size(ex_mem.payload.mem_req.size);
  assign dmem.req_payload.wdata = ex_mem.payload.mem_req.write ? aligned_store_data : '0;
  // 请求端只依赖寄存状态及更老事务的阻塞，不依赖当前响应或下游容量。
  assign request_blocked = flush_i || side_effect_block_i;
  assign dmem.req_valid = ex_mem.valid && memory_instruction && !inflight_q && !request_blocked;

  // CoreBus 保证响应对应已接受或同拍接受的请求。预先给出 ready，避免
  // 响应 ready 依赖请求 ready；响应和元数据仅在 MEM/WB 可接收时一起转移。
  assign dmem.rsp_ready = ex_mem.valid && memory_instruction && result.ready && !flush_i;

  always_comb begin
    if (flush_i) ex_mem.ready = 1'b0;
    else if (memory_instruction) ex_mem.ready = dmem.rsp_fire;
    else ex_mem.ready = result.ready;
  end

  // 响应优先，同拍请求和响应不留下在途事务。flush 不取消已发送的请求。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) inflight_q <= 1'b0;
    else if (dmem.rsp_fire) inflight_q <= 1'b0;
    else if (dmem.req_fire) inflight_q <= 1'b1;
  end

  load_data_unit u_load_data_unit (
    .size_i(ex_mem.payload.mem_req.size),
    .sign_ext_i(ex_mem.payload.mem_req.sign_ext),
    .addr_offset_i(ex_mem.payload.mem_req.addr[1:0]),
    .rdata_i(dmem.rsp_payload.rdata),
    .load_data_o(loaded_data)
  );

  // 访存完成、异常归并与 MEM/WB 仲裁

  // 非访存直接传递；访存仅在响应有效时形成完成事务。
  assign result.valid = ex_mem.valid && (!memory_instruction || dmem.rsp_valid) && !flush_i;

  always_comb begin
    next_payload = ex_mem.payload.commit_ctx;
    if (memory_instruction) begin
      if (dmem.rsp_payload.error) begin
        next_payload.exception = raise_exception(next_payload.exception,
            ex_mem.payload.mem_req.write ? EXC_STORE_ACCESS_FAULT : EXC_LOAD_ACCESS_FAULT,
            ex_mem.payload.mem_req.addr);
      end
      if (next_payload.exception.valid) begin
        next_payload.wb_req = '0;
      end else if (!ex_mem.payload.mem_req.write && next_payload.wb_req.valid) begin
        next_payload.wb_req.data_valid = 1'b1;
        next_payload.wb_req.wdata = loaded_data;
      end
    end
  end

  // 本级输出送入顶层 MEM/WB 寄存器。
  assign result.payload = next_payload;

  // 协议检查

`ifndef SYNTHESIS
  import riscv_debug_pkg::*;

  assign debug_o = '{
    valid: ex_mem.valid, ready: ex_mem.ready,
    mem: '{mem_op: !ex_mem.payload.mem_req.valid ? RETIRE_MEM_NONE :
                       (ex_mem.payload.mem_req.write ? RETIRE_MEM_WRITE : RETIRE_MEM_READ),
           mem_size: ex_mem.payload.mem_req.size,
           mem_addr: ex_mem.payload.mem_req.addr,
           mem_data: ex_mem.payload.mem_req.valid && !ex_mem.payload.mem_req.write ?
                         (next_payload.exception.valid ? '0 : loaded_data) :
                         ex_mem.payload.mem_req.wdata},
    bus: '{req_valid: dmem.req_valid, req_ready: dmem.req_ready,
           rsp_valid: dmem.rsp_valid, rsp_ready: dmem.rsp_ready}
  };

  DmemResponseOwned: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !dmem.rsp_fire || inflight_q || dmem.req_fire));
  DmemSingleInflight: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !inflight_q || !dmem.req_fire));
  DmemInflightMetadata: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !inflight_q || (ex_mem.valid && memory_instruction)));
  DmemInflightNoFlush: assert property (@(posedge clk_i) disable iff (!rst_ni) (
      !inflight_q || !flush_i));
`endif

endmodule
