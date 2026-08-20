// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 仅用于仿真的核心顶层。
//
// 与 ysyx_25080230 并列存在，但不包含 AXI、CLINT 或外部 SoC 引脚；两个内部
// CoreBus 分别连接 DPI-C 存储器模型。调试与性能 interface 的字段在顶层逐一展开，
// 避免仿真器对顶层 interface port 的限制。

module riscv_core_sim
  import riscv_core_pkg::*;
#(
  parameter int unsigned ImemResponseLatency = 1,
  parameter int unsigned ImemMaxOutstanding = 1,
  parameter int unsigned DmemResponseLatency = 1,
  parameter int unsigned DmemMaxOutstanding = 1
) (
  input logic clk_i,
  input logic rst_ni,
  input pc_t boot_pc_i,
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
  output logic [63:0] performance_if_id_fire_count,
  output logic [63:0] performance_id_ex_fire_count,
  output logic [63:0] performance_ex_mem_fire_count,
  output logic [63:0] performance_mem_wb_fire_count,
  output logic [63:0] performance_if_id_stall_cycle_count,
  output logic [63:0] performance_id_ex_stall_cycle_count,
  output logic [63:0] performance_ex_mem_stall_cycle_count,
  output logic [63:0] performance_mem_wb_stall_cycle_count,
  output logic [63:0] performance_if_starve_cycle_count,
  output logic [63:0] performance_id_local_stall_cycle_count,
  output logic [63:0] performance_ex_local_stall_cycle_count,
  output logic [63:0] performance_mem_local_stall_cycle_count,
  output logic [63:0] performance_wb_local_stall_cycle_count
);

  core_bus_if imem_bus ();
  core_bus_if dmem_bus ();
  retire_debug_if retire_debug_int ();
  performance_debug_if performance_int ();

  logic unused_icache_invalidate;

  assign debug_retire_valid = retire_debug_int.valid;
  assign debug_retire_pc = retire_debug_int.payload.meta.pc;
  assign debug_retire_instr = retire_debug_int.payload.meta.instr;
  assign debug_retire_instid = retire_debug_int.payload.meta.instid;
  assign debug_retire_redirect_valid = retire_debug_int.payload.redirect.valid;
  assign debug_retire_redirect_target = retire_debug_int.payload.redirect.target_pc;
  assign debug_retire_mem_op = retire_debug_int.payload.mem.mem_op;
  assign debug_retire_mem_size = retire_debug_int.payload.mem.mem_size;
  assign debug_retire_mem_addr = retire_debug_int.payload.mem.mem_addr;
  assign debug_retire_mem_data = retire_debug_int.payload.mem.mem_data;
  assign debug_retire_gpr_we = retire_debug_int.payload.gpr_we;
  assign debug_retire_gpr_waddr = retire_debug_int.payload.gpr_waddr;
  assign debug_retire_gpr_wdata = retire_debug_int.payload.gpr_wdata;
  assign debug_retire_mstatus = retire_debug_int.payload.csr.mstatus;
  assign debug_retire_mtvec = retire_debug_int.payload.csr.mtvec;
  assign debug_retire_mepc = retire_debug_int.payload.csr.mepc;
  assign debug_retire_mcause = retire_debug_int.payload.csr.mcause;
  assign debug_retire_mtval = retire_debug_int.payload.csr.mtval;
  assign performance_cycle_count = performance_int.payload.cycle_count;
  assign performance_instret_count = performance_int.payload.instret_count;
  assign performance_if_id_fire_count = performance_int.payload.if_id_fire_count;
  assign performance_id_ex_fire_count = performance_int.payload.id_ex_fire_count;
  assign performance_ex_mem_fire_count = performance_int.payload.ex_mem_fire_count;
  assign performance_mem_wb_fire_count = performance_int.payload.mem_wb_fire_count;
  assign performance_if_id_stall_cycle_count = performance_int.payload.if_id_stall_cycle_count;
  assign performance_id_ex_stall_cycle_count = performance_int.payload.id_ex_stall_cycle_count;
  assign performance_ex_mem_stall_cycle_count = performance_int.payload.ex_mem_stall_cycle_count;
  assign performance_mem_wb_stall_cycle_count = performance_int.payload.mem_wb_stall_cycle_count;
  assign performance_if_starve_cycle_count = performance_int.payload.if_starve_cycle_count;
  assign
      performance_id_local_stall_cycle_count = performance_int.payload.id_local_stall_cycle_count;
  assign
      performance_ex_local_stall_cycle_count = performance_int.payload.ex_local_stall_cycle_count;
  assign
      performance_mem_local_stall_cycle_count = performance_int.payload.mem_local_stall_cycle_count;
  assign
      performance_wb_local_stall_cycle_count = performance_int.payload.wb_local_stall_cycle_count;

  riscv_core_impl u_core_impl (
    .clk_i,
    .rst_ni,
    .boot_pc_i,
    .imem(imem_bus),
    .dmem(dmem_bus),
    .icache_invalidate_o(unused_icache_invalidate),
    .debug_retire(retire_debug_int),
    .performance(performance_int)
  );

  mem_sim #(
    .IsDmem(1'b0),
    .ResponseLatency(ImemResponseLatency),
    .MaxOutstanding(ImemMaxOutstanding)
  ) u_imem_sim (
    .clk_i,
    .rst_ni,
    .core_bus(imem_bus)
  );

  mem_sim #(
    .IsDmem(1'b1),
    .ResponseLatency(DmemResponseLatency),
    .MaxOutstanding(DmemMaxOutstanding)
  ) u_dmem_sim (
    .clk_i,
    .rst_ni,
    .core_bus(dmem_bus)
  );

endmodule

/* verilator lint_off DECLFILENAME */

// 仿真专用存储器。每个已接受请求都先进入延迟队列，再产生至少一拍后的响应。
// IsDmem=0 时使用指令读取 DPI-C 函数，IsDmem=1 时使用数据访问 DPI-C 函数。
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

  logic [31:0] rsp_data_q[QueueDepth];
  logic rsp_write_q[QueueDepth];
  logic rsp_error_q[QueueDepth];
  delay_t rsp_delay_q[QueueDepth];
  logic rsp_slot_valid_q[QueueDepth];
  index_t head_q;
  index_t tail_q;
  count_t count_q;

  logic queue_has_space;
  logic response_valid;
  logic request_fire;
  logic response_fire;

  function automatic index_t next_index(input index_t index);
    if (index == index_t'(QueueDepth - 1)) return '0;
    return index + index_t'(1);
  endfunction

  assign queue_has_space = count_q < count_t'(QueueDepth);
  assign
      response_valid = (count_q != '0) && rsp_slot_valid_q[head_q] && (rsp_delay_q[head_q] == '0);
  // 队列满时，即使当前周期正在消费响应，也不接受新请求。这样不会在
  // 同一时钟边沿复用 head/tail 槽位，响应完成后下一周期再重新发 ready。
  assign core_bus.req_ready = queue_has_space;
  assign core_bus.rsp_valid = response_valid;
  assign
      core_bus.rsp_payload.rdata = response_valid && !rsp_write_q[head_q] ? rsp_data_q[head_q] : '0;
  assign core_bus.rsp_payload.error = response_valid ? rsp_error_q[head_q] : 1'b0;

  assign request_fire = core_bus.req_valid && core_bus.req_ready;
  assign response_fire = core_bus.rsp_valid && core_bus.rsp_ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin : mem_sim_state
    int unsigned dpi_rdata;
    bit dpi_error;

    if (!rst_ni) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      for (int unsigned i = 0; i < QueueDepth; i++) begin
        rsp_data_q[i] <= '0;
        rsp_write_q[i] <= 1'b0;
        rsp_error_q[i] <= 1'b0;
        rsp_delay_q[i] <= '0;
        rsp_slot_valid_q[i] <= 1'b0;
      end
    end else begin
      for (int unsigned i = 0; i < QueueDepth; i++) begin
        if (rsp_slot_valid_q[i] && !(request_fire && (tail_q == index_t'(i))) &&
            (rsp_delay_q[i] != '0)) begin
          rsp_delay_q[i] <= rsp_delay_q[i] - delay_t'(1);
        end
      end

      if (response_fire) begin
        rsp_slot_valid_q[head_q] <= 1'b0;
        head_q <= next_index(head_q);
      end

      // DPI-C is deliberately called only for an accepted request and only on
      // the clock edge that accepts it. The returned value is queued with the
      // request, so combinational response logic never touches the DPI model.
      if (request_fire) begin
        dpi_rdata = '0;
        dpi_error = 1'b0;
        if (IsDmem) begin
          dpi_dmem_access_sim(core_bus.req_payload.addr, core_bus.req_payload.write, {
                              6'b0, core_bus.req_payload.size}, core_bus.req_payload.wdata, {
                              4'b0, core_bus.req_payload.wstrb}, dpi_rdata, dpi_error);
        end else begin
          dpi_imem_read_sim(core_bus.req_payload.addr, dpi_rdata, dpi_error);
        end
        // The DPI result must enter the queue as a clocked update. In
        // particular, it must not overwrite the current response slot while
        // a response is being consumed.
        rsp_data_q[tail_q] <= dpi_rdata;
        rsp_error_q[tail_q] <= dpi_error;
        rsp_write_q[tail_q] <= IsDmem && core_bus.req_payload.write;
        rsp_delay_q[tail_q] <= delay_t'(ResponseDelay);
        rsp_slot_valid_q[tail_q] <= 1'b1;
        tail_q <= next_index(tail_q);
      end

      unique case ({
        request_fire, response_fire
      })
        2'b10: count_q <= count_q + count_t'(1);
        2'b01: count_q <= count_q - count_t'(1);
        default: ;
      endcase
    end
  end

endmodule

/* verilator lint_on DECLFILENAME */
