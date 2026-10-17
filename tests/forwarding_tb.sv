// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

module forwarding_tb;
  import riscv_core_pkg::*;

  id_ex_if decoded ();
  id_ex_if forwarded ();
  writeback_payload_t ex_wb, mem_wb, wb;

  forwarding_unit dut (
    .decoded, .ex_wb_i(ex_wb), .mem_wb_i(mem_wb), .wb_i(wb), .result(forwarded)
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
    ex_wb = '0;
    mem_wb = '0;
    wb = '0;

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

    mem_wb = '{valid: 1, data_valid: 1, rd_addr: 1, wdata: 30};
    wb = '{valid: 1, data_valid: 1, rd_addr: 1, wdata: 40};
    check_result("MEM wins over WB", 1, 30, 20);
    ex_wb = '{valid: 1, data_valid: 1, rd_addr: 1, wdata: 50};
    check_result("EX wins over both older producers", 1, 50, 20);
    ex_wb.data_valid = 0;
    check_result("unready EX blocks both older values", 0, 10, 20);
    ex_wb.valid = 0;
    ex_wb.data_valid = 1;
    check_result("invalid EX candidate ignores ready payload", 1, 30, 20);

    ex_wb = '{valid: 1, data_valid: 0, rd_addr: 2, wdata: 60};
    check_result("rs2 can independently block", 0, 30, 20);
    decoded.payload.reg_addr.rs2_used = 0;
    check_result("unused rs2 cannot stall", 1, 30, 20);
    decoded.payload.reg_addr.rs2_used = 1;
    ex_wb.data_valid = 1;
    check_result("sources forward from different stages", 1, 30, 60);
    ex_wb.valid = 0;

    mem_wb.data_valid = 0;
    check_result("unready MEM producer blocks older WB", 0, 10, 20);
    wb.rd_addr = 2;
    check_result("load wait with independent WB source", 0, 10, 40);
    mem_wb.data_valid = 1;
    mem_wb.wdata = 70;
    forwarded.ready = 0;
    check_result("MEM response forwards without a handshake", 1, 70, 40);
    forwarded.ready = 1;
    check_result("release backpressure", 1, 70, 40);
    mem_wb.valid = 0;
    check_result("invalid MEM candidate ignores ready payload", 1, 10, 40);
    wb.data_valid = 0;
    check_result("unready WB cannot forward", 0, 10, 20);
    wb.data_valid = 1;

    mem_wb = '{valid: 1, data_valid: 0, rd_addr: 1, wdata: 80};
    decoded.payload.reg_addr.rs1_used = 0;
    check_result("unused rs1 cannot stall", 1, 10, 40);
    decoded.payload.reg_addr.rs1_used = 1;
    decoded.payload.reg_addr.rs1_addr = 0;
    decoded.payload.exec_data.rs1_value = 0;
    mem_wb.rd_addr = 0;
    ex_wb = '{valid: 1, data_valid: 1, rd_addr: 0, wdata: 90};
    check_result("x0 cannot forward or stall", 1, 0, 40);
    ex_wb.valid = 0;
    decoded.payload.reg_addr.rs1_addr = 1;
    mem_wb.rd_addr = 1;
    mem_wb.valid = 0;
    check_result("invalid writeback request ignored", 1, 0, 40);
    wb.valid = 0;
    check_result("invalid WB ignored", 1, 0, 20);
    decoded.valid = 0;
    check_result("empty input", 1, 0, 20);

    $display("PASS: EX/MEM/WB candidate priority, unready producers, source usage and handshake");
    $finish;
  end
endmodule
