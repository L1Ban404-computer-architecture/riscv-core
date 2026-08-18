// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Cache 全局维护控制器。
//
// 接收一笔 clean-all 或 invalidate-all，请求普通控制面完全排空，再独占 array
// 维护扫描和 line-write 通道。clean 的每条脏行采用独立写回事务；AXI 写回
// 完成后才向 array 确认成功，失败时确认终止但保留 dirty，并向请求方报告错误。
`include "common/assertions.svh"

module cache_maintenance
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

  cache_maintenance_if.handler maintenance,
  output logic quiesce_request,
  input logic quiesce_idle,
  cache_array_maintenance_if.controller array_maintenance,
  axi_line_write_if.requester line_write
);

  typedef enum logic [2:0] {
    StateIdle,
    StateDrain,
    StateArrayRequest,
    StateScan,
    StateWritebackRequest,
    StateWritebackWait,
    StateResponse
  } state_e;

  state_e state_q;
  cache_maintenance_op_e operation_q;
  logic error_q;

  logic maintenance_req_fire;
  logic maintenance_rsp_fire;
  logic array_req_fire;
  logic array_line_fire;
  logic array_done_fire;
  logic line_write_req_fire;
  logic line_write_rsp_fire;

  assign maintenance_req_fire = maintenance.req_valid && maintenance.req_ready;
  assign maintenance_rsp_fire = maintenance.rsp_valid && maintenance.rsp_ready;
  assign array_req_fire = array_maintenance.req_valid && array_maintenance.req_ready;
  assign array_line_fire = array_maintenance.line_valid && array_maintenance.line_ready;
  assign array_done_fire = array_maintenance.done_valid && array_maintenance.done_ready;
  assign line_write_req_fire = line_write.req_valid && line_write.req_ready;
  assign line_write_rsp_fire = line_write.rsp_valid && line_write.rsp_ready;

  // 请求 valid 在被锁存前就阻止新 CoreBus 准入，明确同周期维护请求优先于普通请求。
  assign quiesce_request = (state_q != StateIdle) || maintenance.req_valid;

  always_comb begin
    maintenance.req_ready = state_q == StateIdle;
    maintenance.rsp_valid = state_q == StateResponse;
    maintenance.rsp_payload.error = error_q;

    array_maintenance.req_valid = 1'b0;
    array_maintenance.req_payload.op = operation_q;
    array_maintenance.line_ready = 1'b0;
    array_maintenance.line_success = 1'b0;
    array_maintenance.done_ready = 1'b0;

    line_write.req_valid = 1'b0;
    line_write.req_payload.block_addr = array_maintenance.line_payload.block_addr;
    line_write.req_payload.line = array_maintenance.line_payload.line;
    line_write.rsp_ready = 1'b0;

    unique case (state_q)
      StateArrayRequest: begin
        array_maintenance.req_valid = 1'b1;
      end

      StateScan: begin
        array_maintenance.done_ready = 1'b1;
      end

      StateWritebackRequest: begin
        line_write.req_valid = array_maintenance.line_valid;
      end

      StateWritebackWait: begin
        // array 保持当前 line，直到 line-write response 与 line 同拍完成确认。
        line_write.rsp_ready = array_maintenance.line_valid;
        array_maintenance.line_ready = line_write.rsp_valid;
        array_maintenance.line_success = line_write.rsp_valid && !line_write.rsp_payload.error;
      end

      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= StateIdle;
      operation_q <= CACHE_MAINTENANCE_CLEAN_ALL;
      error_q <= 1'b0;
    end else begin
      unique case (state_q)
        StateIdle: begin
          if (maintenance_req_fire) begin
            operation_q <= maintenance.req_payload.op;
            error_q <= 1'b0;
            state_q <= StateDrain;
          end
        end

        StateDrain: begin
          if (quiesce_idle) state_q <= StateArrayRequest;
        end

        StateArrayRequest: begin
          if (array_req_fire) state_q <= StateScan;
        end

        StateScan: begin
          if (array_maintenance.line_valid) state_q <= StateWritebackRequest;
          else if (array_done_fire) state_q <= StateResponse;
        end

        StateWritebackRequest: begin
          if (line_write_req_fire) state_q <= StateWritebackWait;
        end

        StateWritebackWait: begin
          if (line_write_rsp_fire && array_line_fire) begin
            error_q <= line_write.rsp_payload.error;
            state_q <= StateScan;
          end
        end

        StateResponse: begin
          if (maintenance_rsp_fire) state_q <= StateIdle;
        end

        default: state_q <= StateIdle;
      endcase
    end
  end

  // verilog_format: off
  `ASSERT_INIT(CacheMaintenanceInterfaceWidths,
               $bits(array_maintenance.line_payload.block_addr) == BlockAddrW &&
                   $bits(array_maintenance.line_payload.line) == LineBits &&
                   $bits(line_write.req_payload.block_addr) == BlockAddrW &&
                   $bits(line_write.req_payload.line) == LineBits,
               "Cache maintenance geometry must match the array and line-write interfaces.")
  `ASSERT(CacheMaintenanceRequestStable,
          maintenance.req_valid && !maintenance.req_ready |=>
              $stable({maintenance.req_valid, maintenance.req_payload}),
          clk_i, !rst_ni,
          "A maintenance request must remain stable while backpressured.")
  `ASSERT(CacheMaintenanceResponseStable,
          maintenance.rsp_valid && !maintenance.rsp_ready |=>
              $stable({maintenance.rsp_valid, maintenance.rsp_payload}),
          clk_i, !rst_ni,
          "A maintenance response must remain stable while backpressured.")
  `ASSERT(CacheMaintenanceArrayRequestStable,
          array_maintenance.req_valid && !array_maintenance.req_ready |=>
              $stable({array_maintenance.req_valid, array_maintenance.req_payload}),
          clk_i, !rst_ni,
          "An array maintenance request must remain stable while backpressured.")
  `ASSERT(CacheMaintenanceLineWriteRequestStable,
          line_write.req_valid && !line_write.req_ready |=>
              $stable({line_write.req_valid, line_write.req_payload}),
          clk_i, !rst_ni,
          "A maintenance writeback request must remain stable while backpressured.")
  `ASSERT(CacheMaintenanceLineWriteResponseExpected,
          line_write.rsp_valid |-> (state_q == StateWritebackWait),
          clk_i, !rst_ni,
          "A maintenance line-write response requires an outstanding dirty line.")
  `ASSERT(CacheMaintenanceStartsAfterDrain,
          array_maintenance.req_valid |-> quiesce_idle,
          clk_i, !rst_ni,
          "Array maintenance may start only after the ordinary control plane drains.")
  `ASSERT(CacheMaintenanceLineAndResponseTogether,
          array_line_fire == line_write_rsp_fire,
          clk_i, !rst_ni,
          "A dirty line must be acknowledged exactly with its AXI writeback response.")
  // verilog_format: on

endmodule
