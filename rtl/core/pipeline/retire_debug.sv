// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 独立影子流水线只消费调试事件，不向功能流水施加反压。
`ifndef SYNTHESIS
module retire_debug
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
  import riscv_debug_pkg::*;
#(
  parameter int unsigned ExMaxInflight = 1,
  parameter int unsigned MemMaxInflight = 1
) (
  input logic clk_i,
  input logic rst_ni,
  core_debug_if.consumer debug,
  output pipeline_perf_classes_t classes_o,
  output logic retire_valid_o,
  output retire_debug_payload_t retire_o
);

  typedef struct packed {
    pc_t pc;
    logic [63:0] instid;
  } fetch_meta_t;

  typedef struct packed {
    instruction_debug_payload_t meta;
    perf_class_e perf_class;
  } instruction_trace_t;

  typedef struct packed {
    instruction_trace_t instruction;
    retire_redirect_payload_t redirect;
  } ex_trace_t;

  typedef struct packed {
    ex_trace_t executed;
    retire_mem_payload_t mem;
  } mem_trace_t;

  logic [63:0] instid_q;
  fetch_meta_t fetch_meta;
  instruction_trace_t fetched, decoded, executing;
  ex_trace_t executed;
  mem_trace_t completed;
  retire_debug_payload_t retired;
  logic decode_fire, execute_fire, memory_fire, writeback_fire;

  assign decode_fire = debug.decode.valid && debug.decode.ready;
  assign execute_fire = debug.execute.valid && debug.execute.ready;
  assign memory_fire = debug.memory.valid && debug.memory.ready;
  assign writeback_fire = debug.writeback.valid && debug.writeback.ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) instid_q <= 64'd1;
    else if (debug.fetch.request_fire) instid_q <= instid_q + 64'd1;
  end

  fall_through_register #(
    .T(fetch_meta_t)
  ) u_fetch_meta (
    .clk_i,
    .rst_ni,
    .flush_i(debug.control.redirect),
    .valid_i(debug.fetch.request_fire),
    .ready_o(  /* 未使用 */),
    .data_i('{pc: debug.fetch.request_pc, instid: instid_q}),
    .valid_o(  /* 未使用 */),
    .ready_i(debug.fetch.response_fire),
    .data_o(fetch_meta)
  );

  assign fetched = '{
    meta: '{pc: fetch_meta.pc, instr: debug.fetch.instr, instid: fetch_meta.instid},
    perf_class: classify_opcode(debug.fetch.instr[6:0], debug.fetch.access_fault)
  };

  fall_through_register #(
    .T(instruction_trace_t),
    .FlushMask(1'b1)
  ) u_if_id_trace (
    .clk_i,
    .rst_ni,
    .flush_i(debug.control.redirect),
    .valid_i(debug.fetch.result_valid),
    .ready_o(  /* 未使用 */),
    .data_i(fetched),
    .valid_o(  /* 未使用 */),
    .ready_i(debug.decode.ready),
    .data_o(decoded)
  );

  retire_inflight_queue #(
    .T(instruction_trace_t)
  ) u_id_ex_trace (
    .clk_i,
    .rst_ni,
    .flush_i(debug.control.flush_backend),
    .in_fire_i(decode_fire),
    .in_data_i(decoded),
    .out_fire_i(execute_fire),
    .out_data_o(executing)
  );

  retire_inflight_queue #(
    .Depth(ExMaxInflight),
    .T(ex_trace_t)
  ) u_ex_mem_trace (
    .clk_i,
    .rst_ni,
    .flush_i(debug.control.flush_backend),
    .in_fire_i(execute_fire),
    .in_data_i('{instruction: executing, redirect: debug.execute.redirect}),
    .out_fire_i(memory_fire),
    .out_data_o(executed)
  );

  retire_inflight_queue #(
    .Depth(MemMaxInflight),
    .T(mem_trace_t)
  ) u_mem_wb_trace (
    .clk_i,
    .rst_ni,
    .flush_i(debug.control.flush_backend),
    .in_fire_i(memory_fire),
    .in_data_i('{executed: executed, mem: debug.memory.mem}),
    .out_fire_i(writeback_fire),
    .out_data_o(completed)
  );

  assign classes_o = '{
    id_class: decoded.perf_class,
    ex_class: executing.perf_class,
    mem_class: executed.instruction.perf_class,
    wb_class: completed.executed.instruction.perf_class
  };

  always_comb begin
    retired = '0;
    retired.meta = completed.executed.instruction.meta;
    retired.gpr_we = debug.writeback.gpr_we;
    retired.gpr_waddr = debug.writeback.gpr_waddr;
    retired.gpr_wdata = debug.writeback.gpr_wdata;
    retired.mem = completed.mem;
    retired.redirect = completed.executed.redirect;
    retired.csr = debug.csr;
    if (writeback_fire && ((debug.writeback.kind == COMMIT_TRAP) ||
                          (debug.writeback.kind == COMMIT_MRET)))
      retired.mem.mem_op = RETIRE_MEM_NONE;
    if (writeback_fire && (debug.writeback.kind != COMMIT_FENCE_I) &&
        debug.writeback.redirect.valid)
      retired.redirect = debug.writeback.redirect;
  end

  assign retire_valid_o = writeback_fire;
  assign retire_o = retired;

endmodule
`endif
