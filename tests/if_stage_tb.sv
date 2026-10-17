// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 手动提供至少晚一拍的取指回应；真实退休观察器检查 PC 与 instid 对齐。
module if_stage_tb;
  import riscv_core_pkg::*;
  import riscv_debug_pkg::*;
  bit clk = 0, rst_n = 0;
  core_bus_if imem ();
  if_id_if result ();
  redirect_if redirect ();
  core_debug_if debug ();
  logic imem_flush, retire_valid;
  retire_debug_payload_t retired;
  pipeline_perf_classes_t classes;
  bit execute_valid = 0, memory_valid = 0, writeback_valid = 0;
  instruction_debug_payload_t expected[$];
  instruction_debug_payload_t pending;
  bit pending_valid = 0;
  logic [63:0] next_instid = 1;
  int retired_count = 0;

  if_stage dut (
    .clk_i(clk), .rst_ni(rst_n), .boot_pc_i(32'h100), .redirect,
    .imem_flush_o(imem_flush), .imem, .result, .debug_o(debug.fetch)
  );
  retire_debug observer (
    .clk_i(clk), .rst_ni(rst_n), .debug, .classes_o(classes),
    .retire_valid_o(retire_valid), .retire_o(retired)
  );
  assign debug.decode = '{valid: result.valid, ready: result.ready};
  assign debug.execute = '{valid: execute_valid, ready: 1'b1, redirect: '0};
  assign debug.memory = '{valid: memory_valid, ready: 1'b1, mem: '0, bus: '0};
  assign debug.writeback = '{valid: writeback_valid, ready: 1'b1, kind: COMMIT_NORMAL,
      gpr_we: 1'b0, gpr_waddr: '0, gpr_wdata: '0, redirect: '0};
  assign debug.control = '{redirect: redirect.valid, flush_backend: 1'b0};
  assign debug.csr = '0;

  // 将已接受的取指依次推进模拟 EX/MEM/WB，只观察元数据，不增加功能反压。
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      execute_valid <= 0;
      memory_valid <= 0;
      writeback_valid <= 0;
    end else begin
      execute_valid <= result.fire;
      memory_valid <= execute_valid;
      writeback_valid <= memory_valid;
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      expected.delete();
      pending_valid = 0;
      next_instid = 1;
      retired_count = 0;
    end else begin
      if (retire_valid) begin
        assert (expected.size() != 0) else $fatal(1, "unexpected retirement");
        assert (retired.meta == expected.pop_front()) else $fatal(1, "retired PC/instr/instid");
        retired_count++;
      end
      if (result.valid) assert (pending_valid && result.payload.meta.pc == pending.pc)
        else $fatal(1, "response PC must match its request");
      if (result.fire) begin
        pending.instr = result.payload.meta.instr;
        expected.push_back(pending);
        pending_valid = 0;
      end
      if (redirect.valid) pending_valid = 0;
      if (imem.req_fire) begin
        if (!redirect.valid) begin
          pending = '{pc: imem.req_payload.addr, instr: '0, instid: next_instid};
          pending_valid = 1;
        end
        next_instid++;
      end
    end
  end

  task automatic tick;
    #1; clk = 1;
    #1; clk = 0;
    #1;
  endtask

  initial begin
    redirect.valid = 0;
    redirect.target_pc = 'h200;
    imem.req_ready = 0;
    imem.rsp_valid = 0;
    imem.rsp_payload = '{rdata: 'h00100093, error: 0};
    result.ready = 1;
    tick();
    rst_n = 1;
    imem.req_ready = 1;
    tick(); // 请求 0x100，instid 1。
    imem.rsp_valid = 1;
    #1;
    assert (result.fire && result.payload.meta.pc == 'h100)
      else $fatal(1, "one-cycle response must not gain a metadata bubble");
    tick(); // 回应 0x100，同时请求 0x104，instid 2。
    imem.req_ready = 0;
    result.ready = 0;
    tick(); // 0x104 的回应在反压期间保持。

    // 改道、旧回应和旧 PC 新请求同拍；旧回应丢弃，旧请求不占元数据槽位。
    redirect.valid = 1;
    imem.req_ready = 1;
    #1;
    assert (!result.valid && imem.rsp_fire) else $fatal(1, "redirect must discard old response");
    tick();
    redirect.valid = 0;
    imem.rsp_valid = 0;
    result.ready = 1;
    #1;
    assert (imem_flush && imem.req_payload.addr == 'h200 && imem.req_fire)
      else $fatal(1, "target request must enter during delayed memory flush");
    tick(); // 目标 0x200，instid 4；instid 3 对应的旧请求已取消。
    imem.rsp_valid = 1;
    tick(); // 回应 0x200，同时请求 0x204，instid 5。
    tick(); // 回应 0x204，同时请求 0x208，instid 6。

    // 无回应时改道，同样不能保留改道当拍的旧 PC 请求元数据。
    redirect.valid = 1;
    redirect.target_pc = 'h300;
    imem.rsp_valid = 0;
    tick();
    redirect.valid = 0;
    tick(); // 目标 0x300，instid 8。
    imem.req_ready = 0;
    imem.rsp_valid = 1;
    tick();
    imem.rsp_valid = 0;
    repeat (5) tick();
    assert (retired_count == 4 && expected.size() == 0 && !pending_valid)
      else $fatal(1, "only four accepted instructions may retire");
    $display("PASS: fetch metadata latency, redirect cancellation and retired PC/instid alignment");
    $finish;
  end
endmodule
