// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 仅用于仿真的核心顶层。
//
// 与 ysyx_25080230 并列存在，但不包含 AXI、CLINT 或外部 SoC 引脚；两个内部
// CoreBus 分别连接 DPI-C 存储器模型。调试与性能快照的字段在顶层逐一展开，
// 避免仿真器对顶层 interface port 的限制。

module riscv_core_sim
  import riscv_core_pkg::*;
`ifndef SYNTHESIS
  import riscv_debug_pkg::*;
`endif
#(
  parameter int unsigned ImemResponseLatency = 1,
  parameter int unsigned ImemMaxOutstanding  = 1,
  parameter int unsigned DmemResponseLatency = 1,
  parameter int unsigned DmemMaxOutstanding  = 1
) (
  input logic clk_i,
  input logic rst_ni,
  input pc_t boot_pc_i
`ifndef SYNTHESIS
  ,
  output logic debug_retire_valid,
  output logic [31:0] debug_retire_pc,
  output logic [31:0] debug_retire_instr,
  output logic [63:0] debug_retire_instid,
  output logic debug_retire_redirect_valid,
  output logic [31:0] debug_retire_redirect_target,
  output logic [1:0] debug_retire_mem_op,
  output logic [1:0] debug_retire_mem_size,
  output logic [31:0] debug_retire_mem_addr,
  output logic [31:0] debug_retire_mem_data,
  output logic debug_retire_gpr_we,
  output logic [4:0] debug_retire_gpr_waddr,
  output logic [31:0] debug_retire_gpr_wdata,
  output logic [31:0] debug_retire_mstatus,
  output logic [31:0] debug_retire_mtvec,
  output logic [31:0] debug_retire_mepc,
  output logic [31:0] debug_retire_mcause,
  output logic [31:0] debug_retire_mtval,
  output logic [63:0] performance_cycle_count,
  output logic [63:0] performance_instret_count,
  output logic [63:0] performance_redirect_count,
  output logic [63:0] performance_if_local_stall_cycle_count,
  output logic [63:0] performance_class_instret_count[PerfClassCount],
  output logic [63:0] performance_class_id_local_stall_cycle_count[PerfClassCount],
  output logic [63:0] performance_class_ex_local_stall_cycle_count[PerfClassCount],
  output logic [63:0] performance_class_mem_local_stall_cycle_count[PerfClassCount],
  output logic [63:0] performance_class_wb_local_stall_cycle_count[PerfClassCount],
  output logic [63:0] performance_imem_response_count,
  output logic [63:0] performance_imem_latency_cycle_sum,
  output logic [63:0] performance_imem_request_stall_cycle_count,
  output logic [63:0] performance_imem_response_stall_cycle_count,
  output logic [63:0] performance_dmem_response_count,
  output logic [63:0] performance_dmem_latency_cycle_sum,
  output logic [63:0] performance_dmem_request_stall_cycle_count,
  output logic [63:0] performance_dmem_response_stall_cycle_count
`endif
);

  core_bus_if imem_bus ();
  core_bus_if dmem_bus ();

  logic unused_icache_invalidate;
  logic imem_flush;

  riscv_core_impl u_core_impl (
    .clk_i,
    .rst_ni,
    .boot_pc_i,
    .imem(imem_bus),
    .dmem(dmem_bus),
    .imem_flush_o(imem_flush),
    .icache_invalidate_o(unused_icache_invalidate)
`ifndef SYNTHESIS
    , .debug_retire_valid_o(gen_debug.retire_valid),
    .debug_retire_o(gen_debug.retire),
    .performance_o(gen_debug.performance)
`endif
  );

  mem_sim #(
    .IsDmem(1'b0),
    .ResponseLatency(ImemResponseLatency),
    .MaxOutstanding(ImemMaxOutstanding)
  ) u_imem_sim (
    .clk_i,
    .rst_ni,
    .flush_i(imem_flush),
    .core_bus(imem_bus)
  );

  mem_sim #(
    .IsDmem(1'b1),
    .ResponseLatency(DmemResponseLatency),
    .MaxOutstanding(DmemMaxOutstanding)
  ) u_dmem_sim (
    .clk_i,
    .rst_ni,
    .flush_i(1'b0),
    .core_bus(dmem_bus)
  );

  // 仿真输出：字段展开是宿主接口，命名保持稳定。
`ifndef SYNTHESIS
  generate
    begin : gen_debug
      logic retire_valid;
      retire_debug_payload_t retire;
      performance_debug_payload_t performance;
    end
  endgenerate

  assign debug_retire_valid = gen_debug.retire_valid;
  assign debug_retire_pc = gen_debug.retire.meta.pc;
  assign debug_retire_instr = gen_debug.retire.meta.instr;
  assign debug_retire_instid = gen_debug.retire.meta.instid;
  assign debug_retire_redirect_valid = gen_debug.retire.redirect.valid;
  assign debug_retire_redirect_target = gen_debug.retire.redirect.target_pc;
  assign debug_retire_mem_op = gen_debug.retire.mem.mem_op;
  assign debug_retire_mem_size = gen_debug.retire.mem.mem_size;
  assign debug_retire_mem_addr = gen_debug.retire.mem.mem_addr;
  assign debug_retire_mem_data = gen_debug.retire.mem.mem_data;
  assign debug_retire_gpr_we = gen_debug.retire.gpr_we;
  assign debug_retire_gpr_waddr = gen_debug.retire.gpr_waddr;
  assign debug_retire_gpr_wdata = gen_debug.retire.gpr_wdata;
  assign debug_retire_mstatus = gen_debug.retire.csr.mstatus;
  assign debug_retire_mtvec = gen_debug.retire.csr.mtvec;
  assign debug_retire_mepc = gen_debug.retire.csr.mepc;
  assign debug_retire_mcause = gen_debug.retire.csr.mcause;
  assign debug_retire_mtval = gen_debug.retire.csr.mtval;
  assign performance_cycle_count = gen_debug.performance.cycle_count;
  assign performance_instret_count = gen_debug.performance.instret_count;
  assign performance_redirect_count = gen_debug.performance.redirect_count;
  assign performance_if_local_stall_cycle_count = gen_debug.performance.if_local_stall_cycle_count;

  for (genvar i = 0; i < PerfClassCount; i++) begin : gen_perf_classes
    assign performance_class_instret_count[i] = gen_debug.performance.classes[i].instret_count;
    assign performance_class_id_local_stall_cycle_count[i] = gen_debug.performance.classes[i].id_local_stall_cycle_count;
    assign performance_class_ex_local_stall_cycle_count[i] = gen_debug.performance.classes[i].ex_local_stall_cycle_count;
    assign performance_class_mem_local_stall_cycle_count[i] = gen_debug.performance.classes[i].mem_local_stall_cycle_count;
    assign performance_class_wb_local_stall_cycle_count[i] = gen_debug.performance.classes[i].wb_local_stall_cycle_count;
  end

  assign performance_imem_response_count = gen_debug.performance.imem.response_count;
  assign performance_imem_latency_cycle_sum = gen_debug.performance.imem.latency_cycle_sum;
  assign performance_imem_request_stall_cycle_count = gen_debug.performance.imem.request_stall_cycle_count;
  assign performance_imem_response_stall_cycle_count = gen_debug.performance.imem.response_stall_cycle_count;

  assign performance_dmem_response_count = gen_debug.performance.dmem.response_count;
  assign performance_dmem_latency_cycle_sum = gen_debug.performance.dmem.latency_cycle_sum;
  assign performance_dmem_request_stall_cycle_count = gen_debug.performance.dmem.request_stall_cycle_count;
  assign performance_dmem_response_stall_cycle_count = gen_debug.performance.dmem.response_stall_cycle_count;

`endif

endmodule

/* verilator lint_off DECLFILENAME */

// 请求握手时执行 DPI 访问，将结果放入延迟队列，至少下一拍才能回应。
// 指令侧 flush 清除旧队列，保留同拍新请求；数据侧 flush 接 0。
import "DPI-C" function void dpi_imem_read_sim(
  input int unsigned addr,
  output int unsigned rdata,
  output bit error
);
import "DPI-C" function void dpi_dmem_access_sim(
  input int unsigned addr,
  input bit write,
  input byte unsigned size,
  input int unsigned wdata,
  input byte unsigned wstrb,
  output int unsigned rdata,
  output bit error
);

module mem_sim
  import riscv_bus_pkg::*;
#(
  parameter bit IsDmem = 1'b0,
  parameter int unsigned ResponseLatency = 1,
  parameter int unsigned MaxOutstanding = 1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  core_bus_if.slave core_bus
);

  localparam int unsigned QueueDepth = (MaxOutstanding > 0) ? MaxOutstanding : 1;
  localparam int unsigned IndexWidth = (QueueDepth > 1) ? $clog2(QueueDepth) : 1;
  localparam int unsigned CountWidth = (QueueDepth > 1) ? $clog2(QueueDepth + 1) : 1;
  localparam int unsigned DelayWidth = (ResponseLatency > 1) ? $clog2(ResponseLatency) : 1;
  localparam int unsigned ResponseDelay = (ResponseLatency > 0) ? ResponseLatency - 1 : 0;

  typedef logic [IndexWidth-1:0] index_t;
  typedef logic [CountWidth-1:0] count_t;
  typedef logic [DelayWidth-1:0] delay_t;
  typedef struct packed {
    logic [31:0] rdata;
    logic write;
    logic error;
    delay_t delay_left;
    logic valid;
  } response_t;

  response_t responses_q[QueueDepth];
  index_t head_q;
  index_t tail_q;
  index_t req_index;
  count_t count_q;

  logic response_valid;

  function automatic index_t next_index(input index_t index);
    if (index == index_t'(QueueDepth - 1)) return '0;
    return index + index_t'(1);
  endfunction

  function automatic byte unsigned dpi_wstrb_from_size_addr(input byte unsigned size,
                                                            input logic [1:0] addr_offset);
    unique case (size[1:0])
      2'd0: return 8'h01 << addr_offset;
      2'd1: return 8'h03 << addr_offset;
      default: return 8'h0f;
    endcase
  endfunction

  // 正常运行时满队列不做同拍读写；flush 释放全部槽位，新请求从 0 开始。
  assign req_index = flush_i ? '0 : tail_q;
  assign core_bus.req_ready = flush_i || (count_q < count_t'(QueueDepth));
  assign response_valid = (count_q != '0) && responses_q[head_q].valid &&
      (responses_q[head_q].delay_left == '0);
  assign core_bus.rsp_valid = response_valid && !flush_i;
  assign core_bus.rsp_payload = '{
    rdata: response_valid && !responses_q[head_q].write ? responses_q[head_q].rdata : '0,
    error: response_valid ? responses_q[head_q].error : 1'b0
  };

  always_ff @(posedge clk_i or negedge rst_ni) begin : mem_sim_state
    int unsigned dpi_rdata;
    bit dpi_error;
    byte unsigned dpi_size;
    byte unsigned dpi_wstrb;

    if (!rst_ni) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
      for (int unsigned i = 0; i < QueueDepth; i++) responses_q[i] <= '0;
    end else begin
      if (flush_i) begin
        head_q <= '0;
        tail_q <= core_bus.req_fire ? next_index('0) : '0;
        count_q <= count_t'(core_bus.req_fire);
        for (int unsigned i = 0; i < QueueDepth; i++) responses_q[i].valid <= 1'b0;
      end else begin
        for (int unsigned i = 0; i < QueueDepth; i++) begin
          if (responses_q[i].valid && !(core_bus.req_fire && (tail_q == index_t'(i))) &&
              (responses_q[i].delay_left != '0)) begin
            responses_q[i].delay_left <= responses_q[i].delay_left - delay_t'(1);
          end
        end

        if (core_bus.rsp_fire) begin
          responses_q[head_q].valid <= 1'b0;
          head_q <= next_index(head_q);
        end
        if (core_bus.req_fire) tail_q <= next_index(tail_q);

        unique case ({core_bus.req_fire, core_bus.rsp_fire})
          2'b10: count_q <= count_q + count_t'(1);
          2'b01: count_q <= count_q - count_t'(1);
          default: ;
        endcase
      end

      // 新请求最后入队，使 flush 同拍的请求覆盖刚清空的槽位。
      if (core_bus.req_fire) begin
        dpi_rdata = '0;
        dpi_error = 1'b0;
        if (IsDmem) begin
          dpi_size = {6'b0, core_bus.req_payload.size};
          dpi_wstrb = core_bus.req_payload.write ?
              dpi_wstrb_from_size_addr(dpi_size, core_bus.req_payload.addr[1:0]) : 8'd0;
          dpi_dmem_access_sim(core_bus.req_payload.addr, core_bus.req_payload.write,
              dpi_size, core_bus.req_payload.wdata, dpi_wstrb, dpi_rdata, dpi_error);
        end else begin
          dpi_imem_read_sim(core_bus.req_payload.addr, dpi_rdata, dpi_error);
        end
        responses_q[req_index] <= '{
          rdata: dpi_rdata,
          write: IsDmem && core_bus.req_payload.write,
          error: dpi_error,
          delay_left: delay_t'(ResponseDelay),
          valid: 1'b1
        };
      end
    end
  end

endmodule

/* verilator lint_on DECLFILENAME */
