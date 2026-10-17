// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 真实 EX/MEM 边界与可控总线，检查在途所有权、响应反压和边界取消。
module mem_stage_tb;
  import riscv_core_pkg::*;
  bit clk = 0, rst_n = 0, flush = 0, side_effect_block = 0;
  ex_mem_if source ();
  ex_mem_if executing_memory ();
  mem_wb_if result ();
  core_bus_if dmem ();
  int request_count = 0, response_count = 0;

  stream_register #(.T(ex_mem_payload_t)) u_ex_mem (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .valid_i(source.valid), .ready_o(source.ready), .data_i(source.payload),
    .valid_o(executing_memory.valid), .ready_i(executing_memory.ready),
    .data_o(executing_memory.payload)
  );
  mem_stage dut (
    .clk_i(clk), .rst_ni(rst_n), .side_effect_block_i(side_effect_block),
    .ex_mem(executing_memory), .dmem, .result, .debug_o()
  );

  always @(posedge clk) begin
    if (!rst_n) begin
      request_count = 0;
      response_count = 0;
    end else begin
      if (dmem.req_fire) request_count++;
      if (dmem.rsp_fire) response_count++;
    end
  end

  task automatic tick;
    #1; clk = 1;
    #1; clk = 0;
    #1;
  endtask

  function automatic ex_mem_payload_t memory_packet(input bit write, input mem_size_e size,
                                                    input word_t addr, input word_t data);
    ex_mem_payload_t packet;
    packet = '0;
    packet.commit_ctx.pc = 'h400;
    packet.commit_ctx.wb_req = '{valid: !write, data_valid: 0, rd_addr: 3, wdata: '0};
    packet.mem_req = '{valid: 1, write: write, size: size, sign_ext: 1, addr: addr, wdata: data};
    return packet;
  endfunction

  task automatic send(input ex_mem_payload_t packet);
    source.payload = packet;
    source.valid = 1;
    #1;
    assert (source.ready) else $fatal(1, "test transaction must enter EX/MEM");
    tick();
    source.valid = 0;
    #1;
  endtask

  initial begin
    ex_mem_payload_t packet;
    source.valid = 0;
    source.payload = '0;
    dmem.req_ready = 0;
    dmem.rsp_valid = 0;
    dmem.rsp_payload = '0;
    result.ready = 1;
    tick();
    rst_n = 1;

    // 普通运算结果直接推进，不产生总线访问。
    packet = '0;
    packet.commit_ctx.wb_req = '{valid: 1, data_valid: 1, rd_addr: 3, wdata: 'h1234};
    send(packet);
    assert (result.fire && executing_memory.fire && !dmem.req_valid && !dmem.rsp_ready &&
            result.payload.wb_req.wdata == 'h1234) else $fatal(1, "non-memory passthrough");
    tick();

    // 提交屏障阻挡新请求；请求发出后只等待一次响应，不能重复发出。
    side_effect_block = 1;
    send(memory_packet(0, MEM_SIZE_BYTE, 'h1001, 0));
    dmem.req_ready = 1;
    #1;
    assert (!dmem.req_valid && !result.valid) else $fatal(1, "commit barrier");
    tick();
    side_effect_block = 0;
    #1;
    assert (dmem.req_fire && !executing_memory.ready && dmem.req_payload.addr == 'h1001 &&
            dmem.req_payload.size == riscv_bus_pkg::CORE_BUS_SIZE_BYTE)
      else $fatal(1, "delayed load request");
    tick();
    side_effect_block = 1; // 屏障不阻挡已经发出请求的响应。
    repeat (2) begin
      assert (!dmem.req_valid && !result.valid && executing_memory.valid)
        else $fatal(1, "inflight request must retain metadata without reissuing");
      tick();
    end

    // 下游反压时，响应和 EX/MEM 都不能提前完成；load 的符号扩展值仍有效。
    result.ready = 0;
    dmem.rsp_valid = 1;
    dmem.rsp_payload.rdata = 'h0080ff00;
    #1;
    assert (result.valid && !result.fire && !dmem.rsp_ready && !executing_memory.ready &&
            result.payload.wb_req.data_valid && result.payload.wb_req.wdata == 'hffffffff)
      else $fatal(1, "load response backpressure and sign extension");
    tick();
    assert (request_count == 1 && response_count == 0 && !dmem.req_valid)
      else $fatal(1, "backpressure must not consume or duplicate a response");
    result.ready = 1;
    #1;
    assert (dmem.rsp_fire && executing_memory.fire && result.fire)
      else $fatal(1, "load response and metadata must complete together");
    tick();
    dmem.rsp_valid = 0;
    side_effect_block = 0;

    // 同拍请求和响应不能留下在途状态，下一笔访存仍可立即发出。
    send(memory_packet(0, MEM_SIZE_WORD, 'h2000, 0));
    dmem.rsp_valid = 1;
    dmem.rsp_payload.rdata = 'h12345678;
    #1;
    assert (dmem.req_fire && dmem.rsp_fire && result.fire &&
            result.payload.wb_req.wdata == 'h12345678) else $fatal(1, "zero-latency load");
    tick();
    dmem.rsp_valid = 0;
    send(memory_packet(1, MEM_SIZE_HALF, 'h2002, 'hbeef));
    dmem.rsp_valid = 1;
    #1;
    assert (dmem.req_fire && dmem.rsp_fire && result.fire && dmem.req_payload.write &&
            dmem.req_payload.wdata == 'hbeef0000 && !result.payload.wb_req.valid)
      else $fatal(1, "next store must issue once with aligned data");
    tick();
    dmem.rsp_valid = 0;

    // 访存错误产生异常并禁止 GPR 写回。
    for (int write = 0; write < 2; write++) begin
      send(memory_packet(1'(write), MEM_SIZE_WORD, 'h3000, 'h55));
      dmem.rsp_valid = 1;
      dmem.rsp_payload.error = 1;
      #1;
      assert (dmem.req_fire && dmem.rsp_fire && result.fire && result.payload.exception.valid &&
              result.payload.exception.cause == ((write != 0) ? EXC_STORE_ACCESS_FAULT : EXC_LOAD_ACCESS_FAULT) &&
              result.payload.exception.tval == 'h3000 && !result.payload.wb_req.valid)
        else $fatal(1, "memory fault must suppress writeback");
      tick();
      dmem.rsp_valid = 0;
      dmem.rsp_payload.error = 0;
    end

    // 只冲刷尚未被总线接受的请求；EX/MEM valid 屏蔽足以取消全部 MEM 握手。
    dmem.req_ready = 0;
    send(memory_packet(1, MEM_SIZE_WORD, 'h4000, 'h66));
    assert (dmem.req_valid) else $fatal(1, "store must wait for acceptance");
    flush = 1;
    dmem.req_ready = 1;
    #1;
    assert (!executing_memory.valid && !dmem.req_valid && !dmem.rsp_ready && !result.valid)
      else $fatal(1, "upstream cancellation must suppress all MEM side effects");
    tick();
    flush = 0;
    tick();
    assert (!dmem.req_valid && !result.valid && request_count == 5 && response_count == 5)
      else $fatal(1, "cancelled store must never reappear");
    $display("PASS: MEM barrier, single inflight request, response backpressure, faults and cancellation");
    $finish;
  end
endmodule
