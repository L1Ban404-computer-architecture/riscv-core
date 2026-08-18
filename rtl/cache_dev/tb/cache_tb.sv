// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns / 1ps

// Cache 自检 Testbench。
//
// 维护架构参考存储，驱动定向与随机 CoreBus 场景，并组织 AXI 存储模型和
// 顺序计分板完成端到端自检。
// 同一测试覆盖命中、缺失、反压、替换、写回和错误传播；只读配置不得出现
// AXI 写事务；所有请求必须在全局超时前按序完成。
module cache_tb
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
  import cache_pkg::*;
#(
  parameter bit ReadOnly = CacheDefaultReadOnly,
  parameter int unsigned BlockBytes = CacheDefaultBlockBytes,
  parameter int unsigned SetCount = 8,
  parameter int unsigned WayCount = CacheDefaultWayCount,
  parameter int unsigned LookupLatency = CacheDefaultLookupLatency,
  parameter int unsigned MaxOutstanding = CacheDefaultMaxOutstanding,
  parameter int unsigned AxiId = ReadOnly ? ICACHE_AXI_ID : DCACHE_AXI_ID
);

  localparam int unsigned MemoryBytes = 64 * 1024;
  localparam int unsigned ScoreboardDepth = 2048;
  localparam int unsigned CacheLineCount = SetCount * WayCount;

  logic clk_i;
  logic rst_ni;
  core_bus_if core_bus ();
  cache_maintenance_if maintenance ();
  axi4_if axi ();

  logic [7:0] reference_memory[MemoryBytes];

  logic random_backpressure;
  logic force_core_stall;
  logic force_maintenance_stall;
  logic inject_b_error;
  logic inject_r_error;
  logic [31:0] lfsr_q;
  logic core_rsp_ready;

  word_t expected_request_rdata;
  logic expected_request_error;
  logic scoreboard_empty;

  word_t backing_inspect_address;
  word_t backing_inspect_data;
  int unsigned aw_count;
  int unsigned ar_count;
  int unsigned writeback_count;

  int unsigned random_seed;
  int unsigned cycle_count_q;

  //////////////////////////////////////
  // 被测 Cache、AXI 存储模型与计分板 //
  //////////////////////////////////////

  cache #(
    .ReadOnly(ReadOnly),
    .BlockBytes(BlockBytes),
    .SetCount(SetCount),
    .WayCount(WayCount),
    .LookupLatency(LookupLatency),
    .MaxOutstanding(MaxOutstanding),
    .AxiId(AxiId)
  ) u_dut (
    .clk_i,
    .rst_ni,
    .core_bus,
    .maintenance,
    .axi
  );

  cache_axi_memory_model #(
    .MemoryBytes(MemoryBytes),
    .AxiId(AxiId)
  ) u_axi_memory (
    .clk_i,
    .rst_ni,
    .axi,
    .random_backpressure_i(random_backpressure),
    .random_bits_i(lfsr_q[4:0]),
    .inject_b_error_i(inject_b_error),
    .inject_r_error_i(inject_r_error),
    .inspect_address_i(backing_inspect_address),
    .inspect_data_o(backing_inspect_data),
    .aw_count_o(aw_count),
    .ar_count_o(ar_count),
    .writeback_count_o(writeback_count),
    .refill_count_o(  /* 未使用 */)
  );

  cache_corebus_scoreboard #(
    .Depth(ScoreboardDepth)
  ) u_scoreboard (
    .clk_i,
    .rst_ni,
    .core_bus,
    .expected_rdata_i(expected_request_rdata),
    .expected_error_i(expected_request_error),
    .empty_o(scoreboard_empty),
    .pending_o(  /* 未使用 */)
  );

  //////////////////////////////
  // 时钟、随机序列与响应反压 //
  //////////////////////////////

  always #5 clk_i = !clk_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) cycle_count_q <= 0;
    else cycle_count_q <= cycle_count_q + 1;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lfsr_q <= 32'h1ace_b00c;
    end else begin
      lfsr_q <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
    end
  end

  assign core_bus.rsp_ready = core_rsp_ready;
  assign core_rsp_ready = rst_ni && !force_core_stall && (!random_backpressure || lfsr_q[8]);
  assign maintenance.rsp_ready = rst_ni && !force_maintenance_stall;

  ////////////////////////////
  // 参考存储与地址辅助函数 //
  ////////////////////////////

  function automatic word_t reference_word(input word_t address);
    word_t result;

    result = '0;
    for (int unsigned lane = 0; lane < StrbW; lane++) begin
      result[lane*ByteW+:ByteW] = reference_memory[int'(address)+lane];
    end
    return result;
  endfunction

  function automatic word_t aligned_word_address(input word_t address);
    return address & ~word_t'(StrbW - 1);
  endfunction

  function automatic word_t same_set_address(input word_t base, input int unsigned line_number);
    return base + word_t'(line_number * SetCount * BlockBytes);
  endfunction

  ////////////////////////////
  // CoreBus 驱动与等待任务 //
  ////////////////////////////

  task automatic issue_request(input word_t address, input logic write, input core_bus_size_e size,
                               input word_t wdata, input byte_en_t wstrb,
                               input word_t expected_data, input logic expected_fault);
    int unsigned timeout;

    core_bus.req_payload.addr = address;
    core_bus.req_payload.write = write;
    core_bus.req_payload.size = size;
    core_bus.req_payload.wdata = wdata;
    core_bus.req_payload.wstrb = wstrb;
    expected_request_rdata = expected_data;
    expected_request_error = expected_fault;
    core_bus.req_valid = 1'b1;

    timeout = 0;
    do begin
      @(posedge clk_i);
      timeout++;
      if (timeout > 2000) $fatal(1, "CoreBus request timed out.");
    end while (!core_bus.req_ready);

    @(negedge clk_i);
    core_bus.req_valid = 1'b0;
  endtask

  task automatic issue_load(input word_t address, input logic expected_fault = 1'b0);
    issue_request(address, 1'b0, CORE_BUS_SIZE_WORD, '0, '0, reference_word(
                  aligned_word_address(address)), expected_fault);
  endtask

  task automatic issue_store(input word_t address, input core_bus_size_e size,
                             input word_t raw_data);
    word_t aligned_data;
    byte_en_t strobe;
    int unsigned lane;

    aligned_data = '0;
    strobe = '0;
    lane = int'(address[1:0]);
    unique case (size)
      CORE_BUS_SIZE_BYTE: begin
        aligned_data = raw_data << (lane * ByteW);
        strobe = byte_en_t'(4'b0001 << lane);
        reference_memory[int'(address)] = raw_data[7:0];
      end
      CORE_BUS_SIZE_HALF: begin
        aligned_data = raw_data << (lane * ByteW);
        strobe = byte_en_t'(4'b0011 << lane);
        reference_memory[int'(address)] = raw_data[7:0];
        reference_memory[int'(address)+1] = raw_data[15:8];
      end
      default: begin
        aligned_data = raw_data;
        strobe = '1;
        for (int unsigned byte_lane = 0; byte_lane < StrbW; byte_lane++) begin
          reference_memory[int'(address)+byte_lane] = raw_data[byte_lane*ByteW+:ByteW];
        end
      end
    endcase

    issue_request(address, 1'b1, size, aligned_data, strobe, '0, 1'b0);
  endtask

  task automatic set_reference_word(input word_t address, input word_t data);
    word_t aligned_address;

    aligned_address = aligned_word_address(address);
    for (int unsigned lane = 0; lane < StrbW; lane++) begin
      reference_memory[int'(aligned_address)+lane] = data[lane*ByteW+:ByteW];
    end
  endtask

  task automatic start_maintenance(input cache_maintenance_op_e operation);
    int unsigned timeout;

    maintenance.req_payload.op = operation;
    maintenance.req_valid = 1'b1;
    timeout = 0;
    do begin
      @(posedge clk_i);
      timeout++;
      if (timeout > 2000) $fatal(1, "Cache maintenance request timed out.");
    end while (!maintenance.req_ready);
    @(negedge clk_i);
    maintenance.req_valid = 1'b0;
  endtask

  task automatic wait_maintenance_response(input logic expected_error);
    int unsigned timeout;

    timeout = 0;
    while (!maintenance.rsp_valid) begin
      @(posedge clk_i);
      timeout++;
      if (timeout > 20000) $fatal(1, "Cache maintenance response timed out.");
    end
    if (maintenance.rsp_payload.error !== expected_error)
      $fatal(1, "Cache maintenance error mismatch: expected %0d, got %0d.", expected_error,
             maintenance.rsp_payload.error);
    @(posedge clk_i);
    @(negedge clk_i);
  endtask

  task automatic issue_maintenance(input cache_maintenance_op_e operation,
                                   input logic expected_error = 1'b0);
    start_maintenance(operation);
    wait_maintenance_response(expected_error);
  endtask

  task automatic wait_for_responses;
    int unsigned timeout;

    timeout = 0;
    while (!scoreboard_empty) begin
      @(posedge clk_i);
      timeout++;
      if (timeout > 20000) $fatal(1, "CoreBus responses timed out.");
    end
    @(negedge clk_i);
  endtask

  task automatic wait_for_aw_handshake;
    int unsigned timeout;

    timeout = 0;
    while (!(axi.awvalid && axi.awready)) begin
      @(posedge clk_i);
      timeout++;
      if (timeout > 5000) $fatal(1, "Expected AXI AW request did not arrive.");
    end
    @(negedge clk_i);
  endtask

  task automatic wait_for_ar_handshake;
    int unsigned timeout;

    timeout = 0;
    while (!(axi.arvalid && axi.arready)) begin
      @(posedge clk_i);
      timeout++;
      if (timeout > 5000) $fatal(1, "Expected AXI AR request did not arrive.");
    end
    @(negedge clk_i);
  endtask

  task automatic reset_cache;
    if (rst_ni && !scoreboard_empty) $fatal(1, "Cannot reset with expected responses outstanding.");
    rst_ni = 1'b0;
    core_bus.req_valid = 1'b0;
    maintenance.req_valid = 1'b0;
    force_core_stall = 1'b0;
    force_maintenance_stall = 1'b0;
    repeat (3) @(posedge clk_i);
    @(negedge clk_i);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
  endtask

  task automatic check_backing_word(input word_t address);
    word_t expected;

    backing_inspect_address = aligned_word_address(address);
    #1ps;
    expected = reference_word(aligned_word_address(address));
    if (backing_inspect_data !== expected) begin
      $fatal(1, "Backing memory mismatch at %08x: expected %08x, got %08x.", address, expected,
             backing_inspect_data);
    end
  endtask

  ////////////////////////
  // 定向与随机测试场景 //
  ////////////////////////

  task automatic run_load_tests;
    word_t base;
    int unsigned ar_before;
    int unsigned first_hit_cycle;

    base = 32'h0000_1000;
    ar_before = ar_count;
    issue_load(base);
    wait_for_responses();
    if (ar_count != ar_before + 1) $fatal(1, "Cold load must issue exactly one refill.");

    ar_before = ar_count;
    issue_load(base);
    wait_for_responses();
    if (ar_count != ar_before) $fatal(1, "Load hit unexpectedly issued an AXI read.");

    if (MaxOutstanding > 1) begin
      issue_load(base);
      first_hit_cycle = cycle_count_q;
      issue_load(base);
      if (cycle_count_q != first_hit_cycle + 1)
        $fatal(1, "Pipelined load hits were not accepted in consecutive cycles.");
      wait_for_responses();
    end

    if (MaxOutstanding > 1) begin
      word_t miss_address;
      word_t younger_address;

      miss_address = 32'h0000_2200;
      younger_address = 32'h0000_2240;
      issue_load(miss_address);
      issue_load(younger_address);
      wait_for_responses();
    end

    issue_load(base);
    wait_for_responses();
    force_core_stall = 1'b1;
    issue_load(base);
    if (MaxOutstanding > 1) issue_load(base + word_t'(StrbW));
    repeat (5) @(posedge clk_i);
    if (!core_bus.rsp_valid)
      $fatal(1, "A completed load must remain visible during CoreBus backpressure.");
    @(negedge clk_i);
    force_core_stall = 1'b0;
    wait_for_responses();
  endtask

  task automatic run_store_and_replacement_tests;
    word_t base;
    word_t conflict;
    int unsigned aw_before;

    reset_cache();
    base = 32'h0000_3000;
    issue_load(base);
    wait_for_responses();
    issue_store(base + 32'd1, CORE_BUS_SIZE_BYTE, 32'h0000_00a5);
    issue_load(base);
    issue_store(base + 32'd2, CORE_BUS_SIZE_HALF, 32'h0000_beef);
    issue_load(base);
    issue_store(base, CORE_BUS_SIZE_WORD, 32'h7654_3210);
    issue_load(base);
    wait_for_responses();

    for (int unsigned way = 1; way < WayCount; way++) begin
      conflict = same_set_address(base, way);
      issue_load(conflict);
      wait_for_responses();
    end

    aw_before = aw_count;
    conflict = same_set_address(base, WayCount);
    issue_load(conflict);
    wait_for_responses();
    if (aw_count != aw_before + 1)
      $fatal(
          1,
          "Dirty replacement writeback count mismatch: before=%0d after=%0d address=%08x.",
          aw_before,
          aw_count,
          conflict
      );
    check_backing_word(base);

    base = 32'h0000_3800;
    issue_store(base + 32'd3, CORE_BUS_SIZE_BYTE, 32'h0000_005a);
    issue_load(base);
    wait_for_responses();
  endtask

  task automatic run_refill_error_test;
    word_t address;

    reset_cache();
    address = 32'h0000_4400;
    inject_r_error = 1'b1;
    issue_load(address, 1'b1);
    wait_for_ar_handshake();
    inject_r_error = 1'b0;
    wait_for_responses();

    issue_load(address);
    wait_for_responses();
  endtask

  task automatic run_writeback_error_test;
    word_t base;
    word_t conflict;

    reset_cache();
    base = 32'h0000_5000;
    issue_store(base, CORE_BUS_SIZE_WORD, 32'hc001_cafe);
    wait_for_responses();
    for (int unsigned way = 1; way < WayCount; way++) begin
      conflict = same_set_address(base, way);
      issue_load(conflict);
      wait_for_responses();
    end

    inject_b_error = 1'b1;
    conflict = same_set_address(base, WayCount);
    issue_load(conflict, 1'b1);
    wait_for_aw_handshake();
    inject_b_error = 1'b0;
    wait_for_responses();

    issue_load(base);
    wait_for_responses();
  endtask

  task automatic run_maintenance_basic_tests;
    word_t base;
    word_t second;
    word_t discard_address;
    word_t discarded_old_data;
    int unsigned dirty_line_count;
    int unsigned aw_before;
    int unsigned ar_before;

    reset_cache();
    aw_before = aw_count;
    issue_maintenance(CACHE_MAINTENANCE_CLEAN_ALL);
    if (aw_count != aw_before) $fatal(1, "Clean of an empty cache issued an AXI write.");

    base = 32'h0000_7000;
    second = (SetCount > 1) ? base + word_t'(BlockBytes) : same_set_address(base, 1);
    dirty_line_count = (CacheLineCount > 1) ? 2 : 1;
    issue_store(base, CORE_BUS_SIZE_WORD, 32'h1357_9bdf);
    if (dirty_line_count > 1)
      issue_store(second, CORE_BUS_SIZE_WORD, 32'h2468_ace0);
    wait_for_responses();

    aw_before = aw_count;
    ar_before = ar_count;
    random_backpressure = 1'b1;
    issue_maintenance(CACHE_MAINTENANCE_CLEAN_ALL);
    random_backpressure = 1'b0;
    if (aw_count != aw_before + dirty_line_count)
      $fatal(1, "Clean writeback count mismatch: expected %0d new writes, got %0d.",
             dirty_line_count, aw_count - aw_before);
    if (ar_count != ar_before) $fatal(1, "Writeback-only clean issued an AXI read.");
    check_backing_word(base);
    if (dirty_line_count > 1) check_backing_word(second);

    aw_before = aw_count;
    issue_maintenance(CACHE_MAINTENANCE_CLEAN_ALL);
    if (aw_count != aw_before) $fatal(1, "A second clean rewrote already clean lines.");

    ar_before = ar_count;
    issue_load(base);
    if (dirty_line_count > 1) issue_load(second);
    wait_for_responses();
    if (ar_count != ar_before) $fatal(1, "Clean unexpectedly invalidated cache lines.");

    aw_before = aw_count;
    issue_maintenance(CACHE_MAINTENANCE_INVALIDATE_ALL);
    if (aw_count != aw_before) $fatal(1, "Invalidate unexpectedly wrote back cache lines.");
    ar_before = ar_count;
    issue_load(base);
    if (dirty_line_count > 1) issue_load(second);
    wait_for_responses();
    if (ar_count != ar_before + dirty_line_count)
      $fatal(1, "Invalidated lines did not miss on their next access.");

    // invalidate 明确允许丢弃 dirty；恢复参考模型到原 backing value 后检查重新读取。
    reset_cache();
    discard_address = 32'h0000_7800;
    discarded_old_data = reference_word(discard_address);
    issue_store(discard_address, CORE_BUS_SIZE_WORD, 32'hdead_beef);
    wait_for_responses();
    aw_before = aw_count;
    issue_maintenance(CACHE_MAINTENANCE_INVALIDATE_ALL);
    if (aw_count != aw_before) $fatal(1, "Dirty invalidate emitted an AXI writeback.");
    set_reference_word(discard_address, discarded_old_data);
    ar_before = ar_count;
    issue_load(discard_address);
    wait_for_responses();
    if (ar_count != ar_before + 1) $fatal(1, "Dirty invalidation did not discard the cache line.");
  endtask

  task automatic run_maintenance_error_test;
    word_t base;
    word_t second;
    word_t third;
    int unsigned dirty_line_count;
    int unsigned aw_before;
    int unsigned retry_before;

    reset_cache();
    base = 32'h0000_7a00;
    second = (SetCount > 1) ? base + word_t'(BlockBytes) : same_set_address(base, 1);
    third = (SetCount > 1) ? base + word_t'(2 * BlockBytes) : same_set_address(base, 2);
    dirty_line_count = (CacheLineCount > 2) ? 3 : ((CacheLineCount > 1) ? 2 : 1);
    issue_store(base, CORE_BUS_SIZE_WORD, 32'h0bad_f00d);
    if (dirty_line_count > 1)
      issue_store(second, CORE_BUS_SIZE_WORD, 32'h55aa_33cc);
    if (dirty_line_count > 2)
      issue_store(third, CORE_BUS_SIZE_WORD, 32'h1234_5678);
    wait_for_responses();

    aw_before = aw_count;
    if (dirty_line_count > 1) begin
      fork
        begin
          while (aw_count < aw_before + 1) @(posedge clk_i);
          @(negedge clk_i);
          inject_b_error = 1'b1;
          while (aw_count < aw_before + 2) @(posedge clk_i);
          @(negedge clk_i);
          inject_b_error = 1'b0;
        end
        begin
          issue_maintenance(CACHE_MAINTENANCE_CLEAN_ALL, 1'b1);
        end
      join
      if (aw_count != aw_before + 2)
        $fatal(1, "Clean did not stop at the injected second-line writeback error.");
    end else begin
      inject_b_error = 1'b1;
      issue_maintenance(CACHE_MAINTENANCE_CLEAN_ALL, 1'b1);
      inject_b_error = 1'b0;
      if (aw_count != aw_before + 1)
        $fatal(1, "Single-line clean did not report its writeback error.");
    end

    retry_before = aw_count;
    issue_maintenance(CACHE_MAINTENANCE_CLEAN_ALL);
    if (aw_count != retry_before + ((dirty_line_count > 1) ? dirty_line_count - 1 : 1))
      $fatal(1, "Clean retry did not preserve the failed and unscanned dirty lines.");
    retry_before = aw_count;
    issue_maintenance(CACHE_MAINTENANCE_CLEAN_ALL);
    if (aw_count != retry_before) $fatal(1, "Successful retry left a dirty cache line behind.");
  endtask

  task automatic run_maintenance_ordering_test;
    word_t base;
    int unsigned timeout;

    reset_cache();
    base = 32'h0000_7c00;
    force_core_stall = 1'b1;
    issue_load(base);
    start_maintenance(CACHE_MAINTENANCE_CLEAN_ALL);

    timeout = 0;
    while (!core_bus.rsp_valid) begin
      @(posedge clk_i);
      timeout++;
      if (timeout > 5000) $fatal(1, "Expected pre-maintenance CoreBus response did not arrive.");
    end
    if (maintenance.rsp_valid)
      $fatal(1, "Maintenance completed before an older CoreBus response was accepted.");

    @(negedge clk_i);
    core_bus.req_payload.addr = base + word_t'(BlockBytes);
    core_bus.req_payload.write = 1'b0;
    core_bus.req_payload.size = CORE_BUS_SIZE_WORD;
    core_bus.req_payload.wdata = '0;
    core_bus.req_payload.wstrb = '0;
    core_bus.req_valid = 1'b1;
    repeat (5) begin
      @(posedge clk_i);
      if (core_bus.req_ready) $fatal(1, "Maintenance failed to block a younger CoreBus request.");
    end
    @(negedge clk_i);
    core_bus.req_valid = 1'b0;
    force_core_stall = 1'b0;
    wait_for_responses();
    wait_maintenance_response(1'b0);

    // 即使维护操作本身已结束，响应被反压时仍保持 quiesce。
    force_maintenance_stall = 1'b1;
    start_maintenance(CACHE_MAINTENANCE_INVALIDATE_ALL);
    timeout = 0;
    while (!maintenance.rsp_valid) begin
      @(posedge clk_i);
      timeout++;
      if (timeout > 5000) $fatal(1, "Backpressured maintenance response did not arrive.");
    end
    @(negedge clk_i);
    core_bus.req_payload.addr = base;
    core_bus.req_valid = 1'b1;
    repeat (5) begin
      @(posedge clk_i);
      if (core_bus.req_ready)
        $fatal(1, "CoreBus resumed before the maintenance response handshake.");
    end
    @(negedge clk_i);
    core_bus.req_valid = 1'b0;
    force_maintenance_stall = 1'b0;
    wait_maintenance_response(1'b0);
  endtask

  task automatic run_readonly_maintenance_tests;
    word_t base;
    int unsigned aw_before;
    int unsigned ar_before;

    reset_cache();
    aw_before = aw_count;
    issue_maintenance(CACHE_MAINTENANCE_CLEAN_ALL);
    if (aw_count != aw_before) $fatal(1, "Read-only clean emitted an AXI write.");

    base = 32'h0000_7e00;
    issue_load(base);
    wait_for_responses();
    issue_maintenance(CACHE_MAINTENANCE_INVALIDATE_ALL);
    ar_before = ar_count;
    issue_load(base);
    wait_for_responses();
    if (ar_count != ar_before + 1) $fatal(1, "Read-only invalidate did not clear valid state.");
  endtask

  task automatic run_random_test;
    int unsigned operation;
    int unsigned size_choice;
    word_t address;
    word_t raw_data;
    core_bus_size_e size;

    reset_cache();
    random_backpressure = 1'b1;
    void'($urandom(random_seed));
    for (int unsigned iteration = 0; iteration < 250; iteration++) begin
      operation = $urandom_range(ReadOnly ? 0 : 3, 0);
      address = 32'h0000_6000 + word_t'($urandom_range(2047, 0));
      raw_data = word_t'($urandom());

      if (operation == 0) begin
        address = aligned_word_address(address);
        issue_load(address);
      end else begin
        size_choice = $urandom_range(2, 0);
        unique case (size_choice)
          0: size = CORE_BUS_SIZE_BYTE;
          1: begin
            size = CORE_BUS_SIZE_HALF;
            address[0] = 1'b0;
          end
          default: begin
            size = CORE_BUS_SIZE_WORD;
            address[1:0] = '0;
          end
        endcase
        issue_store(address, size, raw_data);
      end
    end
    wait_for_responses();
    random_backpressure = 1'b0;
  endtask

  ////////////////////////
  // 测试流程与全局超时 //
  ////////////////////////

  initial begin
    clk_i = 1'b0;
    rst_ni = 1'b0;
    core_bus.req_payload = '0;
    core_bus.req_payload.size = CORE_BUS_SIZE_BYTE;
    core_bus.req_valid = 1'b0;
    maintenance.req_payload.op = CACHE_MAINTENANCE_CLEAN_ALL;
    maintenance.req_valid = 1'b0;
    expected_request_rdata = '0;
    expected_request_error = 1'b0;
    backing_inspect_address = '0;
    random_backpressure = 1'b0;
    force_core_stall = 1'b0;
    force_maintenance_stall = 1'b0;
    inject_b_error = 1'b0;
    inject_r_error = 1'b0;
    random_seed = 32'h2508_0230;
    void'($value$plusargs("seed=%d", random_seed));

    for (int unsigned address = 0; address < MemoryBytes; address++) begin
      reference_memory[address] = 8'((address * 17) ^ (address >> 3) ^ 8'h5a);
    end

    reset_cache();
    run_load_tests();
    if (!ReadOnly) begin
      run_store_and_replacement_tests();
      run_refill_error_test();
      if (WayCount > 1) run_writeback_error_test();
      run_maintenance_basic_tests();
      run_maintenance_error_test();
    end else begin
      run_readonly_maintenance_tests();
    end
    run_maintenance_ordering_test();
    run_random_test();

    if (ReadOnly && (aw_count != 0 || writeback_count != 0))
      $fatal(1, "Read-only cache emitted an AXI write transaction.");
    if (!scoreboard_empty) $fatal(1, "Responses remain in the test scoreboard.");

    $display("CACHE_TB_PASS ReadOnly=%0d SetCount=%0d WayCount=%0d seed=%0d", ReadOnly, SetCount,
             WayCount, random_seed);
    $finish;
  end

  initial begin
    #5ms;
    $fatal(1, "Cache testbench global timeout.");
  end

endmodule
