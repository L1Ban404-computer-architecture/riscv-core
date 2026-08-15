// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Cache AXI4 汇聚器。
//
// 将 ICache 与 DCache 的 AXI4 接口汇聚到单个外部主接口，并按 AXI ID
// 将读响应送回原请求端。
// 写通道仅由 DCache 使用；读地址冲突时 DCache 优先；AR 反压期间必须保持
// 请求源不变；每路读响应具有独立 credit 和 FIFO，不允许相互阻塞。
`include "common/assertions.svh"

module cache_axi4_mux
  import riscv_common_pkg::*;
  import riscv_bus_pkg::*;
#(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned ICacheAxiId = ICACHE_AXI_ID,
  parameter int unsigned DCacheAxiId = DCACHE_AXI_ID,
  // 每路最大未完成读事务数
  parameter int unsigned ICacheReadDepth = 2,
  parameter int unsigned DCacheReadDepth = 1,
  parameter int unsigned ICacheReadCountW =
      (ICacheReadDepth > 1) ? $clog2(ICacheReadDepth + 1) : 1,
  parameter int unsigned DCacheReadCountW =
      (DCacheReadDepth > 1) ? $clog2(DCacheReadDepth + 1) : 1
) (
  // 全局控制
  input logic clk_i,
  input logic rst_ni,

  // Cache 侧与外部 AXI4
  axi4_if.slave icache_axi,
  axi4_if.slave dcache_axi,
  axi4_if.master master_axi
);

  ////////////////////////
  // 私有类型与仲裁状态 //
  ////////////////////////

  typedef struct packed {
    logic [1:0] resp;
    logic [DataWidth-1:0] data;
    logic last;
    logic [IdWidth-1:0] id;
  } read_response_t;

  logic ar_locked_q;
  logic ar_owner_dcache_q;
  logic select_dcache;
  logic master_ar_fire;
  logic icache_ar_fire;
  logic dcache_ar_fire;
  logic icache_ar_credit;
  logic dcache_ar_credit;

  logic [ICacheReadCountW-1:0] icache_read_count_q;
  logic [DCacheReadCountW-1:0] dcache_read_count_q;

  read_response_t master_read_response;
  read_response_t icache_read_response;
  read_response_t dcache_read_response;
  logic icache_read_input_ready;
  logic dcache_read_input_ready;
  logic icache_read_valid;
  logic dcache_read_valid;
  logic icache_read_fire;
  logic dcache_read_fire;

  logic unused_icache_write_payload;

  /////////////////////////
  // 读请求选择与 credit //
  /////////////////////////

  assign icache_ar_credit =
      icache_read_count_q < ICacheReadCountW'(ICacheReadDepth);
  assign dcache_ar_credit =
      dcache_read_count_q < DCacheReadCountW'(DCacheReadDepth);
  assign select_dcache = ar_locked_q ? ar_owner_dcache_q :
      (dcache_axi.arvalid && dcache_ar_credit);

  assign master_read_response = '{
    resp: master_axi.r_payload.resp,
    data: master_axi.r_payload.data,
    last: master_axi.r_payload.last,
    id: master_axi.r_payload.id
  };
  assign icache_read_fire = icache_read_valid && icache_axi.rready;
  assign dcache_read_fire = dcache_read_valid && dcache_axi.rready;

  assign unused_icache_write_payload = ^{icache_axi.aw_payload,
                                        icache_axi.w_payload};

  ////////////////////////
  // AXI 通道仲裁与路由 //
  ////////////////////////

  always_comb begin
    master_axi.awvalid = 1'b0;
    master_axi.aw_payload = '0;
    master_axi.wvalid = 1'b0;
    master_axi.w_payload = '0;
    master_axi.bready = 1'b0;
    master_axi.arvalid = 1'b0;
    master_axi.ar_payload = '0;
    master_axi.rready = 1'b0;

    icache_axi.awready = 1'b0;
    icache_axi.wready = 1'b0;
    icache_axi.bvalid = 1'b0;
    icache_axi.b_payload = '0;
    icache_axi.arready = 1'b0;
    icache_axi.rvalid = 1'b0;
    icache_axi.r_payload = '0;
    dcache_axi.awready = 1'b0;
    dcache_axi.wready = 1'b0;
    dcache_axi.bvalid = 1'b0;
    dcache_axi.b_payload = '0;
    dcache_axi.arready = 1'b0;
    dcache_axi.rvalid = 1'b0;
    dcache_axi.r_payload = '0;

    // 当前只有 DCache 能发起内存写事务，写通道无需仲裁。
    master_axi.awvalid = dcache_axi.awvalid;
    master_axi.aw_payload = dcache_axi.aw_payload;
    dcache_axi.awready = master_axi.awready;

    master_axi.wvalid = dcache_axi.wvalid;
    master_axi.w_payload = dcache_axi.w_payload;
    dcache_axi.wready = master_axi.wready;

    master_axi.bready = dcache_axi.bready;
    dcache_axi.bvalid = master_axi.bvalid;
    dcache_axi.b_payload = master_axi.b_payload;

    // 每笔被接受的读请求都预留一个响应 FIFO credit，因此合法 AXI 响应总能被接收；
    // 同时切断公开主接口上从 RVALID/RID 到 RREADY 的组合路径。
    master_axi.rready = rst_ni;

    // 数据读只在 AR 冲突当拍取得优先权。写事务使用独立 AXI 通道，不在此阻塞取指读。
    if (select_dcache) begin
      master_axi.arvalid = dcache_axi.arvalid && dcache_ar_credit;
      master_axi.ar_payload = dcache_axi.ar_payload;
      dcache_axi.arready = master_axi.arready && dcache_ar_credit;
    end else begin
      master_axi.arvalid = icache_axi.arvalid && icache_ar_credit;
      master_axi.ar_payload = icache_axi.ar_payload;
      icache_axi.arready = master_axi.arready && icache_ar_credit;
    end

    // 空响应 FIFO 采用 fall-through 路径，不增加原有响应延迟；被反压的响应则在本地
    // 锁存，之后按两个 AXI ID 分别独立排空。
    icache_axi.rvalid = icache_read_valid;
    icache_axi.r_payload = icache_read_response;
    dcache_axi.rvalid = dcache_read_valid;
    dcache_axi.r_payload = dcache_read_response;
  end

  assign master_ar_fire = master_axi.arvalid && master_axi.arready;
  assign icache_ar_fire = master_ar_fire && !select_dcache;
  assign dcache_ar_fire = master_ar_fire && select_dcache;

  /////////////////////
  // 分路读响应 FIFO //
  /////////////////////

  stream_fifo #(
    .Depth(ICacheReadDepth),
    .FallThrough(1'b1),
    .SameCycleRW(1'b1),
    .T(read_response_t)
  ) u_icache_read_response_fifo (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .usage_o(  /* 未使用 */),
    .data_i(master_read_response),
    .valid_i(rst_ni && master_axi.rvalid &&
        (master_axi.r_payload.id == IdWidth'(ICacheAxiId))),
    .ready_o(icache_read_input_ready),
    .data_o(icache_read_response),
    .valid_o(icache_read_valid),
    .ready_i(icache_axi.rready)
  );

  stream_fifo #(
    .Depth(DCacheReadDepth),
    .FallThrough(1'b1),
    .SameCycleRW(1'b1),
    .T(read_response_t)
  ) u_dcache_read_response_fifo (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .usage_o(  /* 未使用 */),
    .data_i(master_read_response),
    .valid_i(rst_ni && master_axi.rvalid &&
        (master_axi.r_payload.id == IdWidth'(DCacheAxiId))),
    .ready_o(dcache_read_input_ready),
    .data_o(dcache_read_response),
    .valid_o(dcache_read_valid),
    .ready_i(dcache_axi.rready)
  );

  ///////////////////////////////
  // AR 所有权保持与未完成计数 //
  ///////////////////////////////

  // AXI 对 AR 反压时保持已选请求源。被立即接受的路径不插入寄存器，仍为纯组合传输。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_locked_q <= 1'b0;
      ar_owner_dcache_q <= 1'b0;
    end else if (ar_locked_q) begin
      if (master_ar_fire) ar_locked_q <= 1'b0;
    end else if (master_axi.arvalid && !master_axi.arready) begin
      ar_locked_q <= 1'b1;
      ar_owner_dcache_q <= select_dcache;
    end
  end

  // credit 覆盖从 AR 被接受到响应交付目标 cache 的完整路径。因此某响应 FIFO 已满时，
  // AXI 接口不可能还有同 ID 的另一笔合法响应等待接收。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      icache_read_count_q <= '0;
      dcache_read_count_q <= '0;
    end else begin
      unique case ({icache_ar_fire, icache_read_fire})
        2'b10: icache_read_count_q <= icache_read_count_q +
            ICacheReadCountW'(1);
        2'b01: icache_read_count_q <= icache_read_count_q -
            ICacheReadCountW'(1);
        default: ;
      endcase
      unique case ({dcache_ar_fire, dcache_read_fire})
        2'b10: dcache_read_count_q <= dcache_read_count_q +
            DCacheReadCountW'(1);
        2'b01: dcache_read_count_q <= dcache_read_count_q -
            DCacheReadCountW'(1);
        default: ;
      endcase
    end
  end

  ////////////////////
  // 协议与参数断言 //
  ////////////////////

  `ASSERT_INIT(ICacheReadDepthValid, ICacheReadDepth > 0,
               "ICache read response depth must be greater than zero.")
  `ASSERT_INIT(DCacheReadDepthValid, DCacheReadDepth > 0,
               "DCache read response depth must be greater than zero.")
  `ASSERT(ICacheNeverWrites,
          !icache_axi.awvalid && !icache_axi.wvalid && !icache_axi.bready,
          clk_i, !rst_ni, "ICache must not drive AXI write channels.")
  `ASSERT(CacheReadIdKnown,
          master_axi.rvalid |->
              (master_axi.r_payload.id == IdWidth'(ICacheAxiId)) ||
              (master_axi.r_payload.id == IdWidth'(DCacheAxiId)),
          clk_i, !rst_ni, "AXI read response ID must identify a cache.")
  `ASSERT(ICacheReadResponseExpected,
          master_axi.rvalid &&
              (master_axi.r_payload.id == IdWidth'(ICacheAxiId)) |->
              (icache_read_count_q != '0) || icache_ar_fire,
          clk_i, !rst_ni, "ICache read response must match an accepted request.")
  `ASSERT(DCacheReadResponseExpected,
          master_axi.rvalid &&
              (master_axi.r_payload.id == IdWidth'(DCacheAxiId)) |->
              (dcache_read_count_q != '0) || dcache_ar_fire,
          clk_i, !rst_ni, "DCache read response must match an accepted request.")
  `ASSERT(ICacheReadResponseFits,
          master_axi.rvalid &&
              (master_axi.r_payload.id == IdWidth'(ICacheAxiId)) |->
              icache_read_input_ready,
          clk_i, !rst_ni, "ICache read response FIFO must have space.")
  `ASSERT(DCacheReadResponseFits,
          master_axi.rvalid &&
              (master_axi.r_payload.id == IdWidth'(DCacheAxiId)) |->
              dcache_read_input_ready,
          clk_i, !rst_ni, "DCache read response FIFO must have space.")
  `ASSERT(DCacheWriteId,
          master_axi.bvalid |->
              (master_axi.b_payload.id == IdWidth'(DCacheAxiId)),
          clk_i, !rst_ni, "Only DCache may receive AXI write responses.")

  `ASSERT_INIT(AxiMuxAddressAndIdWidthsValid,
               AddrWidth > 0 && IdWidth > 0)
  `ASSERT_INIT(AxiMuxDataWidthValid,
               DataWidth >= 8 && (DataWidth % 8) == 0 &&
                   (DataWidth & (DataWidth - 1)) == 0)
  `ASSERT_INIT(AxiMuxICacheIdFits, (ICacheAxiId >> IdWidth) == 0)
  `ASSERT_INIT(AxiMuxDCacheIdFits, (DCacheAxiId >> IdWidth) == 0)
  `ASSERT_INIT(AxiMuxAddressWidthMatches,
               $bits(master_axi.aw_payload.addr) == AddrWidth)
  `ASSERT_INIT(AxiMuxDataWidthMatches,
               $bits(master_axi.w_payload.data) == DataWidth)
  `ASSERT_INIT(AxiMuxIdWidthMatches,
               $bits(master_axi.aw_payload.id) == IdWidth)

endmodule
