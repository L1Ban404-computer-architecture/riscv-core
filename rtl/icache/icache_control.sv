// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 超小型 I-cache 阻塞式控制器。
//
// 命中不保存上下文，CoreBus 请求与响应在同拍原子完成。缺失时，CoreBus 请求只在
// AXI AR 同拍握手后才完成；随后仅保存回填位置、目标 word、beat 计数和累计错误。
// 控制器不缓存完整请求和 AXI 返回数据，任一时刻最多处理一笔事务。
`include "common/assertions.svh"

module icache_control
  import riscv_bus_pkg::*;
  import icache_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AxiId = ICACHE_AXI_ID,
  parameter int unsigned BlockBytes = 4,
  parameter int unsigned SetCount = 2,
  parameter int unsigned WayCount = 2,
  localparam int unsigned BlockOffsetW = $clog2(BlockBytes),
  localparam int unsigned SetIndexBits = $clog2(SetCount),
  localparam int unsigned SetIndexW = (SetCount > 1) ? SetIndexBits : 1,
  localparam int unsigned WordCount = BlockBytes / (DataWidth / 8),
  localparam int unsigned WordIndexW = (WordCount > 1) ? $clog2(WordCount) : 1,
  localparam int unsigned WayIndexW = (WayCount > 1) ? $clog2(WayCount) : 1,
  localparam int unsigned BeatIndexW = WordIndexW
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // 全 cache 失效请求与阵列清除使能
  input logic invalidate_i,
  output logic invalidate_apply_o,

  // 外部总线与阵列事务
  core_bus_if.slave core_bus,
  axi4_if.master axi,
  icache_lookup_if.controller lookup,
  icache_refill_if.controller refill
);

  //////////////////////////////
  // 私有类型与最小事务上下文 //
  //////////////////////////////

  // Idle 同时承担组合查询和 AXI AR；Refill 逐拍接收 AXI R；Response 返回 miss 结果。
  typedef enum logic [1:0] {
    StateIdle,
    StateRefill,
    StateResponse
  } state_e;
  typedef logic [SetIndexW-1:0] set_index_t;
  typedef logic [WayIndexW-1:0] way_index_t;
  typedef logic [WordIndexW-1:0] word_index_t;
  typedef logic [BeatIndexW-1:0] beat_index_t;

  state_e state_q;
  set_index_t refill_set_q;
  way_index_t refill_way_q;
  word_index_t response_word_q;
  beat_index_t beat_index_q;
  logic error_q;

  logic hit_fire;
  logic miss_fire;
  logic request_fire;
  logic r_fire;
  logic response_fire;
  logic expected_last;
  logic read_beat_error;
  logic combined_error;
  logic refill_terminate;
  logic invalidate_pending_q;
  logic drain_request_q;
  logic allow_idle_request;

  ////////////////////
  // 地址拆分辅助函数 //
  ////////////////////

  // 右移会自然丢弃行内偏移；单组/单 word 配置显式返回零，避免零宽切片。
  function automatic set_index_t set_from_addr(input logic [AddrWidth-1:0] address);
    set_index_t result;

    result = '0;
    if (SetCount > 1) result = set_index_t'(address >> BlockOffsetW);
    return result;
  endfunction

  function automatic word_index_t word_from_addr(input logic [AddrWidth-1:0] address);
    word_index_t result;

    result = '0;
    if (WordCount > 1) result = word_index_t'(address >> 2);
    return result;
  endfunction

  //////////////////////////////
  // 握手、错误检查与阵列事务 //
  //////////////////////////////

  // pending 期间只允许排空已经展示但尚未握手的组合请求，不接收后来出现的新请求。
  assign allow_idle_request = !invalidate_pending_q || drain_request_q;

  // 命中必须同时具备 CoreBus response ready；缺失必须同时具备 AXI AR ready，
  // 因而 request ready 严格表示对应完整事务已经进入下一阶段。
  assign hit_fire = (state_q == StateIdle) && allow_idle_request && core_bus.req_valid &&
      lookup.rsp_payload.hit && core_bus.rsp_ready;
  assign miss_fire = (state_q == StateIdle) && allow_idle_request && core_bus.req_valid &&
      !lookup.rsp_payload.hit && axi.arready;
  assign request_fire = core_bus.req_valid && core_bus.req_ready;
  assign r_fire = axi.rvalid && axi.rready;
  assign response_fire = core_bus.rsp_valid && core_bus.rsp_ready;

  // RID、RRESP 和 RLAST 任一不符合预期都使整行回填失败。提前 RLAST 或期望末拍
  // 仍未出现 RLAST 时立即终止，避免错误 burst 永久占用控制器。
  assign expected_last = beat_index_q == beat_index_t'(WordCount - 1);
  assign read_beat_error = (axi.r_payload.resp != AXI4_RESP_OKAY) ||
      (axi.r_payload.id != IdWidth'(AxiId)) || (axi.r_payload.last != expected_last);
  assign combined_error = error_q || read_beat_error;
  assign refill_terminate = axi.r_payload.last || expected_last;

  // lookup 是纯组合旁路；只有 hit_fire 才提交一次真实访问到替换策略。
  assign lookup.req_valid = (state_q == StateIdle) && allow_idle_request && core_bus.req_valid;
  assign lookup.req_payload.addr = core_bus.req_payload.addr;
  assign lookup.commit = hit_fire;
  assign refill.begin_valid = miss_fire;
  assign refill.begin_payload.addr = core_bus.req_payload.addr;
  assign refill.begin_payload.way = lookup.rsp_payload.victim_way;

  // 每个 R handshake 直接写入 beat_index 对应的 word，不经过缓存行缓冲区。
  assign refill.beat_valid = r_fire;
  assign refill.beat_payload.set = refill_set_q;
  assign refill.beat_payload.way = refill_way_q;
  assign refill.beat_payload.word = word_index_t'(beat_index_q);
  assign refill.beat_payload.data = axi.r_payload.data;
  assign refill.beat_payload.commit = r_fire && refill_terminate && !combined_error;
  assign refill.read_payload.set = refill_set_q;
  assign refill.read_payload.way = refill_way_q;
  assign refill.read_payload.word = response_word_q;

  // 空闲时可立即清除；已有组合请求则等其 hit 完成或 miss 进入并完成 Response。
  assign invalidate_apply_o = invalidate_pending_q &&
      (((state_q == StateIdle) && (!drain_request_q || hit_fire)) ||
       ((state_q == StateResponse) && response_fire));

  //////////////////////
  // CoreBus 与 AXI 驱动 //
  //////////////////////

  always_comb begin
    // I-cache 永不驱动 AXI 写通道。
    axi.awvalid = 1'b0;
    axi.aw_payload = '0;
    axi.wvalid = 1'b0;
    axi.w_payload = '0;
    axi.bready = 1'b0;
    axi.arvalid = 1'b0;
    axi.ar_payload = '0;
    axi.rready = 1'b0;

    core_bus.req_ready = 1'b0;
    core_bus.rsp_valid = 1'b0;
    core_bus.rsp_payload = '0;

    unique case (state_q)
      StateIdle: begin
        if (!allow_idle_request) begin
          core_bus.req_ready = 1'b0;
        end else if (lookup.rsp_payload.hit) begin
          // rsp_ready 直接门控 req_ready，使命中请求和响应在同一拍原子握手。
          core_bus.req_ready = core_bus.rsp_ready;
          core_bus.rsp_valid = core_bus.req_valid;
          core_bus.rsp_payload.rdata = lookup.rsp_payload.rdata;
        end else begin
          // miss 地址按缓存行对齐；CoreBus ready 与 AXI AR ready 同源。
          axi.arvalid = core_bus.req_valid;
          axi.ar_payload.addr =
              (core_bus.req_payload.addr >> BlockOffsetW) << BlockOffsetW;
          axi.ar_payload.id = IdWidth'(AxiId);
          axi.ar_payload.len = 8'(WordCount - 1);
          axi.ar_payload.size = 3'd2;
          axi.ar_payload.burst = AXI4_BURST_INCR;
          core_bus.req_ready = axi.arready;
        end
      end

      // 返回数据直接写阵列，因此 refill 期间可以持续接收每一个 AXI beat。
      StateRefill: axi.rready = 1'b1;

      StateResponse: begin
        // 成功时组合读回请求 word；失败时返回零并置 error，均保持到响应握手。
        core_bus.rsp_valid = 1'b1;
        core_bus.rsp_payload.rdata = error_q ? '0 : refill.read_data;
        core_bus.rsp_payload.error = error_q;
      end

      default: ;
    endcase
  end

  //////////////////////
  // Invalidate 请求排空 //
  //////////////////////

  // invalidate 一旦采样便保持 pending。若采样时已有尚未握手的组合请求，必须继续
  // 展示同一请求直至握手，以维持 CoreBus/AXI valid 和 payload 稳定；除此之外不再
  // 准入新事务。invalidate_i 持续为高时 pending 不释放，cache 始终保持失效状态。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      invalidate_pending_q <= 1'b0;
      drain_request_q <= 1'b0;
    end else if (!invalidate_pending_q) begin
      if (invalidate_i) begin
        invalidate_pending_q <= 1'b1;
        drain_request_q <=
            (state_q == StateIdle) && core_bus.req_valid && !request_fire;
      end
    end else begin
      if (request_fire) drain_request_q <= 1'b0;
      if (invalidate_apply_o) begin
        drain_request_q <= 1'b0;
        if (!invalidate_i) invalidate_pending_q <= 1'b0;
      end
    end
  end

  ////////////////////////////
  // Miss 回填与响应状态更新 //
  ////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StateIdle;
      refill_set_q <= '0;
      refill_way_q <= '0;
      response_word_q <= '0;
      beat_index_q <= '0;
      error_q <= 1'b0;
    end else begin
      unique case (state_q)
        StateIdle: begin
          if (miss_fire) begin
            // AR handshake 后 CoreBus master 可以撤销请求，因此只锁存后续必需字段。
            refill_set_q <= set_from_addr(core_bus.req_payload.addr);
            refill_way_q <= lookup.rsp_payload.victim_way;
            response_word_q <= word_from_addr(core_bus.req_payload.addr);
            beat_index_q <= '0;
            error_q <= 1'b0;
            state_q <= StateRefill;
          end
        end

        StateRefill: begin
          if (r_fire) begin
            // error_q 跨 beat 累计；无论成功或失败，都在 burst 边界转入响应状态。
            error_q <= combined_error;
            if (refill_terminate) begin
              beat_index_q <= '0;
              state_q <= StateResponse;
            end else begin
              beat_index_q <= beat_index_q + beat_index_t'(1);
            end
          end
        end

        StateResponse: begin
          if (response_fire) begin
            error_q <= 1'b0;
            state_q <= StateIdle;
          end
        end

        default: begin
          state_q <= StateIdle;
          beat_index_q <= '0;
          error_q <= 1'b0;
        end
      endcase
    end
  end

  //////////////////
  // 协议与参数断言 //
  //////////////////

  // verilog_format: off
  `ASSERT(ICacheCoreBusReadOnly,
          core_bus.req_valid |-> !core_bus.req_payload.write &&
              (core_bus.req_payload.size == CORE_BUS_SIZE_WORD) &&
              (core_bus.req_payload.addr[1:0] == 2'b00) &&
              (core_bus.req_payload.wdata == '0) && (core_bus.req_payload.wstrb == '0),
          clk_i, !rst_ni, "ICache only accepts aligned word reads.")
  `ASSERT_STABLE(ICacheCoreBusRequestStable, core_bus.req_valid, core_bus.req_ready,
                 core_bus.req_payload, '0, clk_i, !rst_ni,
                 "CoreBus request must remain stable before its handshake.")
  `ASSERT(ICacheCoreBusRequestValidStable,
          core_bus.req_valid && !core_bus.req_ready |=> core_bus.req_valid,
          clk_i, !rst_ni, "CoreBus request valid must remain asserted while stalled.")
  `ASSERT_STABLE(ICacheCoreBusResponseStable, core_bus.rsp_valid, core_bus.rsp_ready,
                 core_bus.rsp_payload, '0, clk_i, !rst_ni,
                 "CoreBus response must remain stable while stalled.")
  `ASSERT_STABLE(ICacheAxiArStable, axi.arvalid, axi.arready, axi.ar_payload, '0,
                 clk_i, !rst_ni, "AXI AR must remain stable while stalled.")
  `ASSERT(ICacheNeverWrites, !axi.awvalid && !axi.wvalid && !axi.bready,
          clk_i, !rst_ni, "ICache must not drive AXI write channels.")
  `ASSERT(ICacheNoRequestWhileBusy,
          (state_q != StateIdle) |-> !core_bus.req_ready, clk_i, !rst_ni)
  `ASSERT(ICacheInvalidateBlocksNewRequest,
          invalidate_pending_q && !drain_request_q |-> !core_bus.req_ready,
          clk_i, !rst_ni)

  `ASSERT_INIT(ICacheControlDataWidthValid, DataWidth == 32)
  `ASSERT_INIT(ICacheControlBlockBytesValid,
               icache_is_power_of_two(BlockBytes) && (BlockBytes >= 4) &&
                   ((BlockBytes % 4) == 0) && (WordCount <= 256))
  `ASSERT_INIT(ICacheControlSetCountValid, icache_is_power_of_two(SetCount))
  `ASSERT_INIT(ICacheControlWayCountValid, icache_is_power_of_two(WayCount))
  `ASSERT_INIT(ICacheControlAxiIdFits, (AxiId >> IdWidth) == 0)
  // verilog_format: on

endmodule
