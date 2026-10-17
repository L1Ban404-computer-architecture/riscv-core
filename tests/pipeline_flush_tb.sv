// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 使用真实 ID/EX/WB 与流水边界，向 MEM/WB 注入更老的改道指令。
module pipeline_flush_tb;
  import riscv_core_pkg::*;

  bit clk = 0;
  bit rst_n = 0;
  if_id_if fetched ();
  if_id_if decoding ();
  id_ex_if decoded ();
  id_ex_if executing ();
  ex_mem_if executed ();
  ex_mem_if memory ();
  mem_wb_if completion ();
  mem_wb_if completed ();
  mem_wb_if memory_result ();
  core_bus_if dmem ();
  gpr_read_if gpr_read ();
  gpr_write_if wb ();
  csr_read_if csr_read ();
  csr_commit_if csr_commit ();
  csr_status_if csr_status ();
  redirect_if ex_redirect ();
  redirect_if wb_redirect ();
  redirect_if resolved_redirect ();
  logic flush_backend, serialize_block, serialize_ready, side_effect_block;
  logic invalidate;
  bit request_ready = 0;

  assign gpr_read.rs1_value = '0;
  assign gpr_read.rs2_value = '0;
  assign csr_read.data = '0;
  assign csr_read.implemented = 1;
  assign csr_status.mtvec = 'h1000;
  assign csr_status.mepc = 'h2000;
  // 保留年轻 store 且不接受请求，让其后的分支在 EX 反压。
  assign dmem.req_ready = request_ready;
  assign dmem.rsp_valid = 0;
  assign dmem.rsp_payload = '0;
  assign memory_result.ready = 1;

  fall_through_register #(.T(if_id_payload_t)) u_if_id (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(resolved_redirect.valid),
    .valid_i(fetched.valid), .ready_o(fetched.ready), .data_i(fetched.payload),
    .valid_o(decoding.valid), .ready_i(decoding.ready), .data_o(decoding.payload)
  );
  id_stage u_id (
    .serialize_block_i(serialize_block), .if_id(decoding), .result(decoded), .gpr_read,
    .debug_o()
  );
  stream_register #(.T(id_ex_payload_t)) u_id_ex (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush_backend),
    .valid_i(decoded.valid), .ready_o(decoded.ready), .data_i(decoded.payload),
    .valid_o(executing.valid), .ready_i(executing.ready), .data_o(executing.payload)
  );
  ex_stage u_ex (
    .serialize_ready_i(serialize_ready), .id_ex(executing), .csr_read,
    .redirect(ex_redirect), .result(executed), .debug_o()
  );
  stream_register #(.T(ex_mem_payload_t)) u_ex_mem (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush_backend),
    .valid_i(executed.valid), .ready_o(executed.ready), .data_i(executed.payload),
    .valid_o(memory.valid), .ready_i(memory.ready), .data_o(memory.payload)
  );
  stream_register #(.T(mem_wb_payload_t)) u_mem_wb (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .valid_i(completion.valid), .ready_o(completion.ready), .data_i(completion.payload),
    .valid_o(completed.valid), .ready_i(completed.ready), .data_o(completed.payload)
  );
  mem_stage u_mem (
    .clk_i(clk), .rst_ni(rst_n), .side_effect_block_i(side_effect_block),
    .ex_mem(memory), .dmem, .result(memory_result), .debug_o()
  );
  wb_stage u_wb (
    .mem_wb(completed), .csr_commit, .csr_status, .redirect(wb_redirect),
    .icache_invalidate_o(invalidate), .wb, .debug_o()
  );
  pipeline_ctrl u_ctrl (
    .id_ex(executing), .ex_mem(memory), .mem_wb(completed), .ex_redirect, .wb_redirect,
    .serialize_block_o(serialize_block), .serialize_ready_o(serialize_ready),
    .mem_side_effect_block_o(side_effect_block), .resolved_redirect,
    .backend_flush_o(flush_backend), .debug_o()
  );

  task automatic tick;
    #1; clk = 1;
    #1; clk = 0;
    #1;
  endtask

  task automatic check_redirect(input commit_kind_e kind, input pc_t target);
    rst_n = 0;
    fetched.valid = 0;
    fetched.payload = '0;
    completion.valid = 0;
    completion.payload = '0;
    tick();
    rst_n = 1;

    fetched.valid = 1;
    fetched.payload.meta = '{pc: 'h100, instr: 'h00002023}; // sw x0,0(x0)
    tick();
    fetched.payload.meta = '{pc: 'h104, instr: 'h0080006f}; // jal x0,+8
    tick();
    fetched.payload.meta = '{pc: 'h108, instr: 'h00100093}; // addi x1,x0,1
    #1;
    assert (memory.valid && memory.payload.mem_req.valid && memory.payload.mem_req.write)
      else $fatal(1, "younger store must wait in EX/MEM");
    assert (executing.valid && !executing.fire && !ex_redirect.valid)
      else $fatal(1, "younger branch must wait in ID/EX");
    assert (dmem.req_valid && !dmem.req_fire)
      else $fatal(1, "younger store must be waiting for bus acceptance");

    // 更老的 WB 指令不得被自己发起的 flush 屏蔽。
    completion.valid = 1;
    completion.payload.pc = 'h300;
    completion.payload.commit.serialize = 1;
    case (kind)
      COMMIT_TRAP: begin
        completion.payload.exception.valid = 1;
        completion.payload.exception.cause = EXC_ILLEGAL_INSTR;
      end
      COMMIT_MRET: completion.payload.commit.is_mret = 1;
      COMMIT_FENCE_I: completion.payload.commit.fence_i = 1;
      default: $fatal(1, "unexpected redirect kind");
    endcase
    tick();
    completion.valid = 0;
    fetched.valid = 0;
    request_ready = 1; // 总线此时愿意接收，仍不能接受已经取消的年轻请求。
    #1;
    assert (completed.fire && flush_backend && resolved_redirect.valid &&
            resolved_redirect.target_pc == target && !wb.valid)
      else $fatal(1, "WB redirect must commit without a flush feedback loop");
    assert (!decoding.valid && !decoded.fire && !executing.valid &&
            !executing.fire && !ex_redirect.valid && !memory.valid)
      else $fatal(1, "flush must immediately cancel younger decode, branch and store");
    assert (!dmem.req_valid && !dmem.req_fire && !dmem.rsp_ready && !memory_result.valid)
      else $fatal(1, "EX/MEM cancellation must suppress MEM requests, responses and output");
    assert (invalidate == (kind == COMMIT_FENCE_I)) else $fatal(1, "FENCE.I invalidate");
    case (kind)
      COMMIT_TRAP: assert (csr_commit.payload.op == CSR_COMMIT_TRAP)
        else $fatal(1, "trap CSR commit");
      COMMIT_MRET: assert (csr_commit.payload.op == CSR_COMMIT_MRET)
        else $fatal(1, "MRET CSR commit");
      default: assert (csr_commit.payload.op == CSR_COMMIT_NONE)
        else $fatal(1, "FENCE.I must not update CSR");
    endcase

    tick();
    assert (!completed.valid && !flush_backend && !invalidate && !memory.valid &&
            !executing.valid && csr_commit.payload.op == CSR_COMMIT_NONE)
      else $fatal(1, "redirect must commit once and leave the pipeline empty");

    // 改道后的第一条指令可以正常进入，不能重新接收之前等待的旧路径指令。
    fetched.valid = 1;
    fetched.payload.meta = '{pc: target, instr: 'h00200093}; // addi x1,x0,2
    tick();
    fetched.valid = 0;
    assert (executing.valid && executing.payload.meta.pc == target &&
            executing.payload.exec_data.imm == 2)
      else $fatal(1, "post-flush instruction must enter normally");
    request_ready = 0;
  endtask

  initial begin
    check_redirect(COMMIT_TRAP, 'h1000);
    check_redirect(COMMIT_MRET, 'h2000);
    check_redirect(COMMIT_FENCE_I, 'h304);
    $display("PASS: WB trap/MRET/FENCE.I commit and immediate younger-stage cancellation");
    $finish;
  end
endmodule
