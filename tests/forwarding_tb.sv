// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

module forwarding_tb;
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;

  id_ex_if decoded ();
  id_ex_if forwarded ();
  id_ex_if executing ();
  ex_mem_if executed ();
  mem_wb_if completed ();

  forwarding_unit dut (
    .decoded, .id_ex(executing), .ex_mem(executed), .mem_wb(completed), .result(forwarded)
  );

  task automatic check_result(input string label_text, input bit available,
                              input word_t rs1, input word_t rs2);
    id_ex_payload_t expected;
    #1;
    expected = decoded.payload;
    expected.exec_data.rs1_value = rs1;
    expected.exec_data.rs2_value = rs2;
    assert (forwarded.payload === expected) else $fatal(1, "%s: payload", label_text);
    assert (forwarded.valid == (decoded.valid && available))
      else $fatal(1, "%s: valid", label_text);
    assert (decoded.ready == (forwarded.ready && available))
      else $fatal(1, "%s: ready", label_text);
    assert (decoded.fire == forwarded.fire) else $fatal(1, "%s: fire", label_text);
  endtask

  initial begin
    decoded.valid = 1;
    decoded.payload = '0;
    forwarded.ready = 1;
    executing.valid = 0;
    executing.ready = 0;
    executing.payload = '0;
    executed.valid = 0;
    executed.ready = 1;
    executed.payload = '0;
    completed.valid = 0;
    completed.ready = 1;
    completed.payload = '0;

    decoded.payload.meta.pc = 'h30000000;
    decoded.payload.meta.instr = 'h002081b3;
    decoded.payload.ctrl.alu_op = ALU_ADD;
    decoded.payload.exec_data.imm = 'h12345678;
    decoded.payload.reg_addr.rs1_used = 1;
    decoded.payload.reg_addr.rs2_used = 1;
    decoded.payload.reg_addr.rs1_addr = 1;
    decoded.payload.reg_addr.rs2_addr = 2;
    decoded.payload.reg_addr.rd_addr = 3;
    decoded.payload.exec_data.rs1_value = 10;
    decoded.payload.exec_data.rs2_value = 20;
    check_result("GPR passthrough without a clock", 1, 10, 20);

    executed.valid = 1;
    executed.payload.commit_ctx.wb_req = '{valid: 1, data_valid: 1, rd_addr: 1, wdata: 30};
    completed.valid = 1;
    completed.payload.wb_req = '{valid: 1, data_valid: 1, rd_addr: 1, wdata: 40};
    check_result("EX/MEM wins over MEM/WB", 1, 30, 20);

    executing.valid = 1;
    executing.payload.reg_addr.rd_addr = 1;
    executing.payload.ctrl.wb_sel = WB_ALU;
    check_result("EX producer blocks both older values even while EX is stalled", 0, 10, 20);
    executing.ready = 1;
    check_result("EX producer still blocks on its departure cycle", 0, 10, 20);
    executing.payload.ctrl.wb_sel = WB_MEM;
    check_result("EX load also blocks", 0, 10, 20);
    executing.payload.ctrl.wb_sel = WB_PC4;
    check_result("EX link register write also blocks", 0, 10, 20);
    executing.payload.ctrl.wb_sel = WB_CSR;
    check_result("EX CSR GPR write also blocks", 0, 10, 20);
    executing.payload.ctrl.wb_sel = WB_NONE;
    check_result("EX non-writer ignored", 1, 30, 20);
    executing.payload.ctrl.wb_sel = WB_ALU;
    executing.payload.exception.valid = 1;
    check_result("EX instruction with known exception cannot write GPR", 1, 30, 20);
    executing.payload.exception.valid = 0;
    executing.payload.reg_addr.rd_addr = 0;
    check_result("EX write to x0 ignored", 1, 30, 20);
    executing.payload.reg_addr.rd_addr = 1;
    executing.valid = 0;
    check_result("invalid EX transaction ignored", 1, 30, 20);

    executing.valid = 1;
    executing.payload.reg_addr.rd_addr = 2;
    check_result("EX dependency on rs2 blocks independently", 0, 30, 20);
    decoded.payload.reg_addr.rs2_used = 0;
    check_result("unused rs2 cannot stall", 1, 30, 20);
    decoded.payload.reg_addr.rs2_used = 1;
    executing.valid = 0;

    executed.payload.commit_ctx.wb_req.data_valid = 0;
    check_result("unready MEM producer blocks older WB value", 0, 10, 20);
    completed.payload.wb_req.rd_addr = 2;
    check_result("load wait with independent WB source", 0, 10, 40);
    executed.valid = 0;
    completed.payload.wb_req = '{valid: 1, data_valid: 0, rd_addr: 2, wdata: 70};
    check_result("unready WB blocks", 0, 10, 20);
    completed.payload.wb_req.data_valid = 1;
    forwarded.ready = 0;
    check_result("downstream backpressure does not alter data or valid", 1, 10, 70);
    forwarded.ready = 1;
    check_result("release backpressure", 1, 10, 70);

    completed.valid = 0;
    executed.valid = 1;
    executed.payload.commit_ctx.wb_req = '{valid: 1, data_valid: 0, rd_addr: 1, wdata: 80};
    decoded.payload.reg_addr.rs1_used = 0;
    check_result("unused rs1 cannot stall", 1, 10, 20);
    decoded.payload.reg_addr.rs1_used = 1;
    decoded.payload.reg_addr.rs1_addr = 0;
    decoded.payload.exec_data.rs1_value = 0;
    executed.payload.commit_ctx.wb_req.rd_addr = 0;
    executing.valid = 1;
    executing.payload.reg_addr.rd_addr = 0;
    check_result("x0 cannot forward or stall", 1, 0, 20);
    executing.valid = 0;
    decoded.payload.reg_addr.rs1_addr = 1;
    executed.payload.commit_ctx.wb_req.rd_addr = 1;
    executed.payload.commit_ctx.wb_req.valid = 0;
    check_result("invalid writeback request ignored", 1, 0, 20);
    executed.payload.commit_ctx.wb_req.valid = 1;
    executed.valid = 0;
    check_result("invalid MEM producer ignored", 1, 0, 20);
    completed.valid = 1;
    completed.payload.wb_req.valid = 0;
    check_result("invalid WB write ignored", 1, 0, 20);
    decoded.valid = 0;
    check_result("empty input", 1, 0, 20);

    $display("PASS: ID forwarding priority, EX interlock, source usage and handshake");
    $finish;
  end
endmodule
