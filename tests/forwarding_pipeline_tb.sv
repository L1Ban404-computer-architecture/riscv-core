// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 使用真实 GPR 与 ID/EX，检查等待期间的写回和已接收操作数的稳定性。
module forwarding_pipeline_tb;
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;

  bit clk = 0;
  bit rst_n = 0;
  bit flush = 0;
  bit decode_valid = 0;
  id_ex_payload_t decode_payload;
  id_ex_if decoded ();
  id_ex_if forwarded ();
  id_ex_if executing ();
  ex_mem_if executed ();
  mem_wb_if completed ();
  gpr_read_if gpr_read ();
  gpr_write_if wb ();

  assign decoded.valid = decode_valid && !flush;
  always_comb begin
    decoded.payload = decode_payload;
    decoded.payload.exec_data.rs1_value = gpr_read.rs1_value;
    decoded.payload.exec_data.rs2_value = gpr_read.rs2_value;
  end
  assign gpr_read.rs1_addr = decode_payload.reg_addr.rs1_addr;
  assign gpr_read.rs2_addr = decode_payload.reg_addr.rs2_addr;
  assign wb.valid = completed.fire && completed.payload.wb_req.valid &&
      completed.payload.wb_req.data_valid && !flush;
  assign wb.rd_addr = completed.payload.wb_req.rd_addr;
  assign wb.wdata = completed.payload.wb_req.wdata;

  regfile u_regfile (.clk_i(clk), .gpr_read, .wb);
  forwarding_unit dut (
    .decoded, .id_ex(executing), .ex_mem(executed), .mem_wb(completed), .result(forwarded)
  );
  stream_register #(.T(id_ex_payload_t)) u_id_ex_register (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .valid_i(forwarded.valid), .ready_o(forwarded.ready), .data_i(forwarded.payload),
    .valid_o(executing.valid), .ready_i(executing.ready), .data_o(executing.payload)
  );

  task automatic tick;
    #1;
    clk = 1;
    #1;
    clk = 0;
    #1;
  endtask

  initial begin
    decode_payload = '0;
    executing.ready = 1;
    executed.valid = 0;
    executed.ready = 1;
    executed.payload = '0;
    completed.valid = 0;
    completed.ready = 1;
    completed.payload = '0;
    tick();
    rst_n = 1;

    // 初始化真实寄存器堆，不依赖未定义的复位数据。
    completed.valid = 1;
    completed.payload.wb_req = '{valid: 1, data_valid: 1, rd_addr: 1, wdata: 10};
    tick();
    completed.payload.wb_req = '{valid: 1, data_valid: 1, rd_addr: 2, wdata: 20};
    tick();
    completed.valid = 0;

    // 第一条写 x1，下一条读 x1。ID 等待时 EX 仍能离开，不能形成互锁死锁。
    decode_valid = 1;
    decode_payload.ctrl.wb_sel = WB_ALU;
    decode_payload.reg_addr.rd_addr = 1;
    tick();
    decode_payload.reg_addr.rd_addr = 3;
    decode_payload.reg_addr.rs1_addr = 1;
    decode_payload.reg_addr.rs2_addr = 2;
    decode_payload.reg_addr.rs1_used = 1;
    decode_payload.reg_addr.rs2_used = 1;
    #1;
    assert (!decoded.ready && !forwarded.valid && executing.fire)
      else $fatal(1, "adjacent RAW must block ID while EX drains");
    tick();
    executed.valid = 1;
    executed.payload.commit_ctx.wb_req = '{valid: 1, data_valid: 1, rd_addr: 1, wdata: 30};
    #1;
    assert (decoded.fire && forwarded.payload.exec_data.rs1_value == 30)
      else $fatal(1, "consumer must accept producer from EX/MEM after one bubble");
    tick();
    decode_valid = 0;
    executed.valid = 0;
    executing.ready = 0;
    completed.valid = 1;
    completed.payload.wb_req = '{valid: 1, data_valid: 1, rd_addr: 1, wdata: 99};
    tick();
    completed.valid = 0;
    assert (executing.valid && executing.payload.exec_data.rs1_value == 30 &&
            executing.payload.exec_data.rs2_value == 20)
      else $fatal(1, "accepted EX operands must remain stable under backpressure");
    executing.ready = 1;
    tick();

    // rs1 等 load，rs2 的 WB 可以独立离开；之后从真实 GPR 读取提交值。
    decode_valid = 1;
    executed.valid = 1;
    executed.payload.commit_ctx.wb_req = '{valid: 1, data_valid: 0, rd_addr: 1, wdata: 0};
    completed.valid = 1;
    completed.payload.wb_req = '{valid: 1, data_valid: 1, rd_addr: 2, wdata: 40};
    #1;
    assert (!decoded.ready && forwarded.payload.exec_data.rs2_value == 40)
      else $fatal(1, "load blocks ID while independent WB is visible");
    tick();
    completed.valid = 0;
    #1;
    assert (!decoded.ready && forwarded.payload.exec_data.rs2_value == 40)
      else $fatal(1, "WB value must remain available from live GPR after WB leaves");
    tick();
    executed.valid = 0;
    completed.valid = 1;
    completed.payload.wb_req = '{valid: 1, data_valid: 1, rd_addr: 1, wdata: 50};
    #1;
    assert (decoded.fire && forwarded.payload.exec_data.rs1_value == 50 &&
            forwarded.payload.exec_data.rs2_value == 40)
      else $fatal(1, "load completion must release ID with both current source values");
    tick();
    completed.valid = 0;
    decode_valid = 0;
    assert (executing.valid && executing.payload.exec_data.rs1_value == 50 &&
            executing.payload.exec_data.rs2_value == 40)
      else $fatal(1, "ID/EX must latch resolved load and committed WB values");

    // 满载同拍替换，独立指令仍能每拍进入 EX。
    decode_valid = 1;
    decode_payload.meta.pc = 'h30000004;
    #1;
    assert (decoded.fire && executing.fire) else $fatal(1, "same-cycle replacement");
    tick();
    assert (executing.valid && executing.payload.meta.pc == 'h30000004)
      else $fatal(1, "replacement transaction must reach EX");

    // 冲刷必须丢弃 ID 等待事务和 ID/EX，后续事务不能继承旧操作数。
    decode_payload.reg_addr.rs1_addr = 3;
    flush = 1;
    executing.ready = 0;
    #1;
    assert (!forwarded.valid) else $fatal(1, "flush must suppress decode output");
    tick();
    assert (!executing.valid) else $fatal(1, "flush must empty ID/EX");
    decode_payload.reg_addr.rs1_addr = 1;
    decode_payload.meta.pc = 'h30000008;
    flush = 0;
    tick();
    decode_valid = 0;
    assert (executing.valid && executing.payload.meta.pc == 'h30000008 &&
            executing.payload.exec_data.rs1_value == 50)
      else $fatal(1, "post-flush instruction must use current GPR value");

    $display("PASS: ID/EX interlock, live GPR under load wait, operand capture and flush");
    $finish;
  end
endmodule
