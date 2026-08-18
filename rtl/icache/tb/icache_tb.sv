// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns / 1ps

// 超小型 I-cache 自检 Testbench。
//
// 同一套场景用于默认、长缓存行、固定替换和四路 Tree-PLRU 配置，覆盖组合命中、
// AXI refill、双向反压、错误丢弃、全阵列失效及替换状态更新时机。
module icache_tb
  import riscv_bus_pkg::*;
  import icache_pkg::*;
#(
  parameter int unsigned BlockBytes = 4,
  parameter int unsigned SetCount = 2,
  parameter int unsigned WayCount = 2,
  parameter icache_replacement_policy_e ReplacementPolicy = ICACHE_REPLACEMENT_ROUND_ROBIN,
  parameter int unsigned AxiId = ICACHE_AXI_ID
);

  //////////////////////////
  // 接口、控制与观察状态 //
  //////////////////////////

  localparam int unsigned AddrWidth = 32;
  localparam int unsigned DataWidth = 32;
  localparam int unsigned IdWidth = 4;
  localparam int unsigned WordCount = BlockBytes / 4;

  logic clk_i;
  logic rst_ni;
  logic invalidate_i;
  core_bus_if core_bus ();
  axi4_if axi ();

  logic ar_stall;
  logic r_gap;
  logic inject_r_error;
  logic inject_wrong_id;
  logic [1:0] last_mode;
  int unsigned ar_count;
  int unsigned r_count;

  int unsigned cycle_count_q;

  ////////////////////////////
  // 被测 I-cache 与 AXI 模型 //
  ////////////////////////////

  icache #(
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .ReplacementPolicy(ReplacementPolicy),
    .AxiId(AxiId)
  ) u_dut (
    .clk_i,
    .rst_ni,
    .invalidate_i,
    .core_bus,
    .axi
  );

  icache_axi_memory_model u_memory (
    .clk_i,
    .rst_ni,
    .axi,
    .ar_stall_i(ar_stall),
    .r_gap_i(r_gap),
    .inject_r_error_i(inject_r_error),
    .inject_wrong_id_i(inject_wrong_id),
    .last_mode_i(last_mode),
    .ar_count_o(ar_count),
    .r_count_o(r_count)
  );

  //////////////////////
  // 时钟与期望数据模型 //
  //////////////////////

  always #5 clk_i = !clk_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) cycle_count_q <= 0;
    else cycle_count_q <= cycle_count_q + 1;
  end

  function automatic logic [31:0] expected_word(input logic [31:0] address);
    return 32'hc001_0000 ^ address;
  endfunction

  ////////////////////////////
  // CoreBus 驱动与检查任务 //
  ////////////////////////////

  task automatic check(input logic condition, input string message);
    if (!condition) $fatal(1, "%s", message);
  endtask

  task automatic drive_request(input logic [31:0] address);
    core_bus.req_payload.addr = address;
    core_bus.req_payload.write = 1'b0;
    core_bus.req_payload.size = CORE_BUS_SIZE_WORD;
    core_bus.req_payload.wdata = '0;
    core_bus.req_payload.wstrb = '0;
    core_bus.req_valid = 1'b1;
    #1ps;
  endtask

  task automatic wait_response(input logic [31:0] address, input logic expected_error);
    int unsigned timeout;

    timeout = 0;
    while (!core_bus.rsp_valid) begin
      @(negedge clk_i);
      timeout++;
      if (timeout > 200) $fatal(1, "CoreBus response timed out at %08x.", address);
    end
    check(core_bus.rsp_payload.error === expected_error, "CoreBus error mismatch.");
    if (expected_error) check(core_bus.rsp_payload.rdata === '0, "Error response data was not zero.");
    else if (core_bus.rsp_payload.rdata !== expected_word(address))
      $fatal(1, "Instruction data mismatch at %08x: expected %08x, got %08x.", address,
             expected_word(address), core_bus.rsp_payload.rdata);
    @(posedge clk_i);
    @(negedge clk_i);
  endtask

  task automatic fetch(input logic [31:0] address, input logic expect_miss,
                       input logic expected_error = 1'b0);
    int unsigned ar_before;
    int unsigned timeout;

    ar_before = ar_count;
    @(negedge clk_i);
    drive_request(address);
    timeout = 0;
    while (!core_bus.req_ready) begin
      @(negedge clk_i);
      timeout++;
      if (timeout > 100) $fatal(1, "CoreBus request timed out at %08x.", address);
    end

    if (expect_miss) begin
      check(axi.arvalid, "Miss request did not drive AXI ARVALID.");
      check(!core_bus.rsp_valid, "Miss unexpectedly returned a same-cycle response.");
    end else begin
      check(core_bus.rsp_valid, "Hit did not return a same-cycle response.");
      check(!axi.arvalid, "Hit unexpectedly issued an AXI request.");
      check(!core_bus.rsp_payload.error, "Hit returned an error.");
      check(core_bus.rsp_payload.rdata === expected_word(address), "Hit data mismatch.");
    end

    @(posedge clk_i);
    @(negedge clk_i);
    core_bus.req_valid = 1'b0;
    if (expect_miss) begin
      check(ar_count == ar_before + 1, "Miss did not complete exactly one AXI AR handshake.");
      wait_response(address, expected_error);
    end else begin
      check(ar_count == ar_before, "Hit changed the AXI AR count.");
    end
  endtask

  // 恢复所有反压和错误注入开关，确保各定向场景彼此独立。
  task automatic reset_dut;
    rst_ni = 1'b0;
    invalidate_i = 1'b0;
    core_bus.req_valid = 1'b0;
    core_bus.rsp_ready = 1'b1;
    ar_stall = 1'b0;
    r_gap = 1'b0;
    inject_r_error = 1'b0;
    inject_wrong_id = 1'b0;
    last_mode = 2'd0;
    repeat (3) @(posedge clk_i);
    @(negedge clk_i);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);
  endtask

  //////////////////////
  // 定向协议测试场景 //
  //////////////////////

  // 命中响应被反压时，请求不能提前握手，响应数据必须依赖稳定请求保持不变。
  task automatic test_hit_stall;
    logic [31:0] address;
    logic [31:0] held_data;

    address = 32'h0000_1100;
    fetch(address, 1'b1);
    @(negedge clk_i);
    core_bus.rsp_ready = 1'b0;
    drive_request(address);
    #1;
    check(core_bus.rsp_valid && !core_bus.req_ready, "Stalled hit was not atomic.");
    held_data = core_bus.rsp_payload.rdata;
    repeat (3) begin
      @(negedge clk_i);
      check(core_bus.rsp_valid && !core_bus.req_ready, "Stalled hit changed handshake state.");
      check(core_bus.rsp_payload.rdata === held_data, "Stalled hit data changed.");
    end
    core_bus.rsp_ready = 1'b1;
    #1;
    check(core_bus.req_ready && core_bus.rsp_valid, "Released hit did not become ready.");
    @(posedge clk_i);
    @(negedge clk_i);
    core_bus.req_valid = 1'b0;
  endtask

  // AXI AR 反压应直接传回 CoreBus，同时保持行对齐地址和 burst 属性稳定。
  task automatic test_ar_backpressure;
    logic [31:0] address;
    logic [31:0] held_ar_addr;

    address = 32'h0000_2200;
    @(negedge clk_i);
    ar_stall = 1'b1;
    drive_request(address);
    #1;
    check(axi.arvalid && !core_bus.req_ready, "AR stall did not reach CoreBus.");
    check(axi.ar_payload.addr == (address & ~(BlockBytes - 1)), "AR address was not line aligned.");
    check(axi.ar_payload.len == 8'(WordCount - 1), "ARLEN did not match the cache line.");
    held_ar_addr = axi.ar_payload.addr;
    repeat (3) begin
      @(negedge clk_i);
      check(axi.arvalid && (axi.ar_payload.addr == held_ar_addr), "Stalled AR payload changed.");
    end
    ar_stall = 1'b0;
    #1;
    check(core_bus.req_ready, "CoreBus request did not follow ARREADY.");
    @(posedge clk_i);
    @(negedge clk_i);
    core_bus.req_valid = 1'b0;
    wait_response(address, 1'b0);
  endtask

  // 第一笔 miss refill 和响应完成前，不允许第二笔请求并发进入。
  task automatic test_busy_rejection;
    logic [31:0] first_address;
    logic [31:0] second_address;

    first_address = 32'h0000_3300;
    second_address = first_address + BlockBytes;
    @(negedge clk_i);
    r_gap = 1'b1;
    drive_request(first_address);
    while (!core_bus.req_ready) @(negedge clk_i);
    @(posedge clk_i);
    @(negedge clk_i);
    drive_request(second_address);
    repeat (3) begin
      check(!core_bus.req_ready && !axi.arvalid, "Busy cache accepted a concurrent request.");
      @(negedge clk_i);
    end
    r_gap = 1'b0;
    wait_response(first_address, 1'b0);
    while (!core_bus.req_ready) @(negedge clk_i);
    check(axi.arvalid, "Held second request did not issue after the first response.");
    @(posedge clk_i);
    @(negedge clk_i);
    core_bus.req_valid = 1'b0;
    wait_response(second_address, 1'b0);
  endtask

  // 分别注入 RRESP、RID、末拍缺失和提前末拍错误；失败行必须保持无效并重新 miss。
  task automatic test_refill_errors;
    logic [31:0] address;

    address = 32'h0000_4400;
    inject_r_error = 1'b1;
    fetch(address, 1'b1, 1'b1);
    inject_r_error = 1'b0;
    fetch(address, 1'b1, 1'b0);
    fetch(address, 1'b0, 1'b0);

    address = 32'h0000_5500;
    inject_wrong_id = 1'b1;
    fetch(address, 1'b1, 1'b1);
    inject_wrong_id = 1'b0;
    fetch(address, 1'b1, 1'b0);

    address = 32'h0000_6600;
    last_mode = 2'd2;
    fetch(address, 1'b1, 1'b1);
    last_mode = 2'd0;
    fetch(address, 1'b1, 1'b0);

    if (WordCount > 1) begin
      address = 32'h0000_7700;
      last_mode = 2'd1;
      fetch(address, 1'b1, 1'b1);
      last_mode = 2'd0;
      fetch(address, 1'b1, 1'b0);
    end
  endtask

  // 多 word 缓存行逐拍回填后，行内每个 word 都应直接从阵列命中。
  task automatic test_burst_words;
    logic [31:0] base;
    int unsigned ar_before;

    if (WordCount > 1) begin
      base = 32'h0000_8000;
      r_gap = 1'b1;
      fork
        begin
          repeat (3) @(posedge clk_i);
          @(negedge clk_i);
          r_gap = 1'b0;
        end
        fetch(base + 32'd8, 1'b1, 1'b0);
      join
      ar_before = ar_count;
      for (int unsigned word_index = 0; word_index < WordCount; word_index++)
        fetch(base + 32'(word_index * 4), 1'b0, 1'b0);
      check(ar_count == ar_before, "Refilled burst words did not all hit.");
    end
  endtask

  // 空闲失效后保持阻塞直至 invalidate 拉低，原缓存行必须重新 miss。
  task automatic test_invalidate_idle;
    logic [31:0] address;

    reset_dut();
    address = 32'h0000_9000;
    fetch(address, 1'b1, 1'b0);
    fetch(address, 1'b0, 1'b0);

    @(negedge clk_i);
    invalidate_i = 1'b1;
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    drive_request(address);
    repeat (3) begin
      check(!core_bus.req_ready && !axi.arvalid,
            "High invalidate did not block a new request.");
      @(negedge clk_i);
    end

    invalidate_i = 1'b0;
    while (!core_bus.req_ready) @(negedge clk_i);
    check(axi.arvalid, "Invalidated line unexpectedly remained a hit.");
    @(posedge clk_i);
    @(negedge clk_i);
    core_bus.req_valid = 1'b0;
    wait_response(address, 1'b0);
  endtask

  // 已展示且被反压的组合 hit 必须先排空，之后才能清除其有效位。
  task automatic test_invalidate_stalled_hit;
    logic [31:0] address;
    logic [31:0] held_data;

    reset_dut();
    address = 32'h0000_b000;
    fetch(address, 1'b1, 1'b0);
    @(negedge clk_i);
    core_bus.rsp_ready = 1'b0;
    drive_request(address);
    held_data = core_bus.rsp_payload.rdata;
    invalidate_i = 1'b1;
    @(posedge clk_i);
    repeat (2) begin
      @(negedge clk_i);
      check(core_bus.rsp_valid && !core_bus.req_ready,
            "Invalidate dropped a stalled atomic hit.");
      check(core_bus.rsp_payload.rdata === held_data,
            "Invalidate changed stalled hit data.");
    end

    invalidate_i = 1'b0;
    core_bus.rsp_ready = 1'b1;
    #1ps;
    check(core_bus.req_ready && core_bus.rsp_valid,
          "Stalled hit did not drain before invalidation.");
    @(posedge clk_i);
    @(negedge clk_i);
    core_bus.req_valid = 1'b0;
    fetch(address, 1'b1, 1'b0);
  endtask

  // 在途 refill 及其 CoreBus 响应完整结束后再失效刚回填的缓存行。
  task automatic test_invalidate_during_refill;
    logic [31:0] address;

    reset_dut();
    address = 32'h0000_c000;
    @(negedge clk_i);
    r_gap = 1'b1;
    drive_request(address);
    while (!core_bus.req_ready) @(negedge clk_i);
    @(posedge clk_i);
    @(negedge clk_i);
    core_bus.req_valid = 1'b0;
    invalidate_i = 1'b1;
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    r_gap = 1'b0;
    wait_response(address, 1'b0);

    invalidate_i = 1'b0;
    repeat (2) @(posedge clk_i);
    fetch(address, 1'b1, 1'b0);
  endtask

  // 先填满同一组，再按所选策略制造替换并检查预期的保留与淘汰结果。
  task automatic test_replacement;
    logic [31:0] base;
    logic [31:0] stride;
    logic [31:0] new0;
    logic [31:0] new1;

    if (WayCount > 1) begin
      reset_dut();
      base = 32'h0000_a000;
      stride = SetCount * BlockBytes;
      for (int unsigned way = 0; way < WayCount; way++)
        fetch(base + 32'(way) * stride, 1'b1, 1'b0);

      if (ReplacementPolicy == ICACHE_REPLACEMENT_ROUND_ROBIN)
        fetch(base + 32'(WayCount - 1) * stride, 1'b0, 1'b0);

      new0 = base + 32'(WayCount) * stride;
      new1 = base + 32'(WayCount + 1) * stride;
      fetch(new0, 1'b1, 1'b0);
      if (ReplacementPolicy == ICACHE_REPLACEMENT_TREE_PLRU) fetch(new0, 1'b0, 1'b0);
      fetch(new1, 1'b1, 1'b0);

      unique case (ReplacementPolicy)
        ICACHE_REPLACEMENT_FIXED: begin
          fetch(base + stride, 1'b0, 1'b0);
          fetch(new1, 1'b0, 1'b0);
          fetch(new0, 1'b1, 1'b0);
        end
        ICACHE_REPLACEMENT_ROUND_ROBIN: begin
          fetch(new0, 1'b0, 1'b0);
          fetch(new1, 1'b0, 1'b0);
          fetch(base, 1'b1, 1'b0);
        end
        default: begin
          fetch(new0, 1'b0, 1'b0);
          fetch(new1, 1'b0, 1'b0);
          fetch(base + 32'(WayCount / 2) * stride, 1'b1, 1'b0);
        end
      endcase
    end
  endtask

  ////////////////////////
  // 测试流程与全局超时 //
  ////////////////////////

  initial begin
    clk_i = 1'b0;
    rst_ni = 1'b0;
    invalidate_i = 1'b0;
    core_bus.req_payload = '0;
    core_bus.req_valid = 1'b0;
    core_bus.rsp_ready = 1'b1;
    ar_stall = 1'b0;
    r_gap = 1'b0;
    inject_r_error = 1'b0;
    inject_wrong_id = 1'b0;
    last_mode = 2'd0;

    reset_dut();
    test_hit_stall();
    test_ar_backpressure();
    test_busy_rejection();
    test_refill_errors();
    test_burst_words();
    test_invalidate_idle();
    test_invalidate_stalled_hit();
    test_invalidate_during_refill();
    test_replacement();

    check(!axi.awvalid && !axi.wvalid && !axi.bready, "ICache drove an AXI write channel.");
    check(r_count > 0, "AXI memory model did not return any read beats.");
    $display("icache_tb: PASS (BlockBytes=%0d SetCount=%0d WayCount=%0d Policy=%0d)",
             BlockBytes, SetCount, WayCount, ReplacementPolicy);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "Global I-cache test timeout after %0d cycles.", cycle_count_q);
  end

endmodule
