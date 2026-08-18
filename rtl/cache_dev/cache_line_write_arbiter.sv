// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 缓存行写回事务仲裁器。
//
// 将普通 miss 写回和 cache maintenance 写回汇聚到同一个 line-write
// 执行端，并保存已接受事务的来源，确保响应只回到原请求方。维护写回具有
// 优先权；正常情况下 cache control 已经排空，因此两个请求不会同时有效。
`include "common/assertions.svh"

module cache_line_write_arbiter
  import riscv_common_pkg::*;
  import cache_pkg::*;
#(
  parameter int unsigned AddrWidth = XLen,
  parameter int unsigned BlockBytes = CacheDefaultBlockBytes,
  localparam int unsigned BlockAddrW = AddrWidth - $clog2(BlockBytes),
  localparam int unsigned LineBits = BlockBytes * ByteW
) (
  input logic clk_i,
  input logic rst_ni,

  axi_line_write_if.handler control_line_write,
  axi_line_write_if.handler maintenance_line_write,
  axi_line_write_if.requester line_write
);

  logic owner_maintenance_q;
  logic line_write_req_fire;

  assign line_write_req_fire = line_write.req_valid && line_write.req_ready;

  always_comb begin
    line_write.req_valid = 1'b0;
    line_write.req_payload = '0;
    control_line_write.req_ready = 1'b0;
    maintenance_line_write.req_ready = 1'b0;

    // maintenance 写回优先；请求端必须在反压期间保持 valid 和 payload。
    if (maintenance_line_write.req_valid) begin
      line_write.req_valid = 1'b1;
      line_write.req_payload = maintenance_line_write.req_payload;
      maintenance_line_write.req_ready = line_write.req_ready;
    end else begin
      line_write.req_valid = control_line_write.req_valid;
      line_write.req_payload = control_line_write.req_payload;
      control_line_write.req_ready = line_write.req_ready;
    end

    control_line_write.rsp_valid = line_write.rsp_valid && !owner_maintenance_q;
    control_line_write.rsp_payload = line_write.rsp_payload;
    maintenance_line_write.rsp_valid = line_write.rsp_valid && owner_maintenance_q;
    maintenance_line_write.rsp_payload = line_write.rsp_payload;
    line_write.rsp_ready = owner_maintenance_q ? maintenance_line_write.rsp_ready :
        control_line_write.rsp_ready;
  end

  // owner 在请求握手时锁存，并保持到下一笔请求被接受；因此执行端响应即使被
  // 任一上游反压，也不会切换目标。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) owner_maintenance_q <= 1'b0;
    else if (line_write_req_fire) owner_maintenance_q <= maintenance_line_write.req_valid;
  end

  // verilog_format: off
  `ASSERT_INIT(CacheLineWriteArbiterInterfaceWidths,
               $bits(control_line_write.req_payload.block_addr) == BlockAddrW &&
                   $bits(control_line_write.req_payload.line) == LineBits &&
                   $bits(maintenance_line_write.req_payload.block_addr) == BlockAddrW &&
                   $bits(maintenance_line_write.req_payload.line) == LineBits &&
                   $bits(line_write.req_payload.block_addr) == BlockAddrW &&
                   $bits(line_write.req_payload.line) == LineBits,
               "Line-write arbiter geometry must match all connected interfaces.")
  `ASSERT(CacheLineWriteArbiterControlRequestStable,
          control_line_write.req_valid && !control_line_write.req_ready |=>
              $stable({control_line_write.req_valid, control_line_write.req_payload}),
          clk_i, !rst_ni,
          "Control line-write request must remain stable while backpressured.")
  `ASSERT(CacheLineWriteArbiterMaintenanceRequestStable,
          maintenance_line_write.req_valid && !maintenance_line_write.req_ready |=>
              $stable({maintenance_line_write.req_valid, maintenance_line_write.req_payload}),
          clk_i, !rst_ni,
          "Maintenance line-write request must remain stable while backpressured.")
  `ASSERT(CacheLineWriteRequestOwnersExclusive,
          !(control_line_write.req_valid && maintenance_line_write.req_valid),
          clk_i, !rst_ni,
          "Ordinary miss traffic and maintenance writeback traffic must be exclusive.")
  `ASSERT(CacheLineWriteArbiterResponseStable,
          line_write.rsp_valid && !line_write.rsp_ready |=>
              $stable({line_write.rsp_valid, line_write.rsp_payload}),
          clk_i, !rst_ni,
          "Line-write response must remain stable while backpressured.")
  `ASSERT(CacheLineWriteArbiterControlResponseStable,
          control_line_write.rsp_valid && !control_line_write.rsp_ready |=>
              $stable({control_line_write.rsp_valid, control_line_write.rsp_payload}),
          clk_i, !rst_ni,
          "Control line-write response must remain stable while backpressured.")
  `ASSERT(CacheLineWriteArbiterMaintenanceResponseStable,
          maintenance_line_write.rsp_valid && !maintenance_line_write.rsp_ready |=>
              $stable({maintenance_line_write.rsp_valid, maintenance_line_write.rsp_payload}),
          clk_i, !rst_ni,
          "Maintenance line-write response must remain stable while backpressured.")
  // verilog_format: on

  `ASSERT_INIT(CacheLineWriteArbiterAddressWidthSupported, AddrWidth == XLen)
  `ASSERT_INIT(CacheLineWriteArbiterBlockBytesValid, (BlockBytes >= StrbW) && cache_is_power_of_two(
               BlockBytes) && ((BlockBytes % StrbW) == 0),
               "Line-write arbiter block size must be an aligned power of two.")

endmodule
