// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 真实 EX/MEM/WB、GPR 与流水寄存器：检查同拍前递、访存等待、背压和取消。
module forwarding_pipeline_tb;
  import riscv_core_pkg::*;

  bit clk = 0, rst_n = 0, flush = 0, decode_valid = 0;
  bit serialize_ready = 1;
  id_ex_payload_t decode_payload;
  id_ex_if decoded ();
  id_ex_if forwarded ();
  id_ex_if executing ();
  ex_mem_if executed ();
  ex_mem_if memory ();
  mem_wb_if completion ();
  mem_wb_if completed ();
  core_bus_if dmem ();
  gpr_read_if gpr_read ();
  gpr_write_if wb ();
  csr_read_if csr_read ();
  csr_commit_if csr_commit ();
  csr_status_if csr_status ();
  redirect_if ex_redirect ();
  redirect_if wb_redirect ();

  assign decoded.valid = decode_valid && !flush;
  always_comb begin
    decoded.payload = decode_payload;
    decoded.payload.exec_data.rs1_value = gpr_read.rs1_value;
    decoded.payload.exec_data.rs2_value = gpr_read.rs2_value;
  end
  assign gpr_read.rs1_addr = decode_payload.reg_addr.rs1_addr;
  assign gpr_read.rs2_addr = decode_payload.reg_addr.rs2_addr;
  assign csr_read.data = 77;
  assign csr_read.implemented = 1;
  assign csr_status.mtvec = 'h1000;
  assign csr_status.mepc = 'h2000;

  regfile u_regfile (.clk_i(clk), .gpr_read, .wb);
  forwarding_unit dut (
    .decoded, .id_ex(executing), .ex_result(executed), .ex_mem(memory),
    .mem_result(completion), .wb, .result(forwarded)
  );
  stream_register #(.T(id_ex_payload_t)) u_id_ex_register (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .valid_i(forwarded.valid), .ready_o(forwarded.ready), .data_i(forwarded.payload),
    .valid_o(executing.valid), .ready_i(executing.ready), .data_o(executing.payload)
  );
  ex_stage u_ex (
    .serialize_ready_i(serialize_ready), .id_ex(executing), .csr_read,
    .redirect(ex_redirect), .result(executed), .debug_o()
  );
  stream_register #(.T(ex_mem_payload_t)) u_ex_mem_register (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .valid_i(executed.valid), .ready_o(executed.ready), .data_i(executed.payload),
    .valid_o(memory.valid), .ready_i(memory.ready), .data_o(memory.payload)
  );
  mem_stage u_mem (
    .clk_i(clk), .rst_ni(rst_n), .side_effect_block_i(1'b0),
    .ex_mem(memory), .dmem, .result(completion), .debug_o()
  );
  stream_register #(.T(mem_wb_payload_t)) u_mem_wb_register (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .valid_i(completion.valid), .ready_o(completion.ready), .data_i(completion.payload),
    .valid_o(completed.valid), .ready_i(completed.ready), .data_o(completed.payload)
  );
  wb_stage u_wb (
    .mem_wb(completed), .csr_commit, .csr_status, .redirect(wb_redirect),
    .icache_invalidate_o(), .wb, .debug_o()
  );

  task automatic tick;
    #1; clk = 1;
    #1; clk = 0;
    #1;
  endtask

  function automatic id_ex_payload_t addi(input reg_addr_t rd, input reg_addr_t rs1,
                                         input word_t imm);
    id_ex_payload_t packet;
    packet = '0;
    packet.reg_addr.rd_addr = rd;
    packet.reg_addr.rs1_addr = rs1;
    packet.reg_addr.rs1_used = 1;
    packet.exec_data.imm = imm;
    packet.ctrl.alu_op = ALU_ADD;
    packet.ctrl.op_b_sel = OP_B_IMM;
    packet.ctrl.wb_sel = WB_ALU;
    return packet;
  endfunction

  function automatic id_ex_payload_t add(input reg_addr_t rd, input reg_addr_t rs1,
                                        input reg_addr_t rs2);
    id_ex_payload_t packet;
    packet = addi(rd, rs1, 0);
    packet.reg_addr.rs2_addr = rs2;
    packet.reg_addr.rs2_used = 1;
    packet.ctrl.op_b_sel = OP_B_RS2;
    return packet;
  endfunction

  function automatic id_ex_payload_t load(input reg_addr_t rd, input mem_size_e size,
                                         input word_t addr);
    id_ex_payload_t packet;
    packet = addi(rd, 0, addr);
    packet.ctrl.wb_sel = WB_MEM;
    packet.ctrl.mem_cmd = MEM_LOAD;
    packet.ctrl.mem_size = size;
    packet.ctrl.mem_sign_ext = 1;
    return packet;
  endfunction

  task automatic issue(input id_ex_payload_t packet);
    decode_payload = packet;
    decode_valid = 1;
    #1;
    assert (decoded.fire) else $fatal(1, "instruction must enter ID/EX without a bubble");
    tick();
    decode_valid = 0;
  endtask

  task automatic drain;
    decode_valid = 0;
    repeat (3) tick();
    assert (!executing.valid && !memory.valid && !completed.valid)
      else $fatal(1, "pipeline must drain");
  endtask

  initial begin
    id_ex_payload_t packet;
    decode_payload = '0;
    dmem.req_ready = 1;
    dmem.rsp_valid = 0;
    dmem.rsp_payload = '0;
    tick();
    rst_n = 1;

    // 使用真实指令初始化 GPR；相邻 RAW 必须同拍前递并替换 ID/EX。
    issue(addi(1, 0, 10));
    issue(addi(2, 0, 20));
    drain();
    issue(addi(1, 0, 30));
    decode_payload = add(3, 1, 2);
    decode_valid = 1;
    #1;
    assert (executing.fire && decoded.fire &&
            forwarded.payload.exec_data.rs1_value == 30 &&
            forwarded.payload.exec_data.rs2_value == 20)
      else $fatal(1, "adjacent ALU RAW must forward from EX with no bubble");
    tick();
    decode_valid = 0;
    assert (executing.payload.exec_data.rs1_value == 30 &&
            executed.payload.commit_ctx.wb_req.wdata == 50)
      else $fatal(1, "consumer must execute in the next cycle with captured EX result");
    issue(addi(4, 3, 1));
    assert (executed.payload.commit_ctx.wb_req.wdata == 51)
      else $fatal(1, "back-to-back dependent ALU chain");
    drain();

    // 同一 rd 连续写入，EX 必须覆盖 MEM/WB 中的旧结果。
    issue(addi(1, 0, 5));
    issue(addi(1, 1, 1));
    issue(addi(1, 1, 1));
    assert (executed.payload.commit_ctx.wb_req.wdata == 7 &&
            completion.payload.wb_req.wdata == 6 && wb.wdata == 5)
      else $fatal(1, "youngest EX producer must win over two older writers");
    drain();

    // load 在 EX 尚未就绪时，不能绕过它取 MEM 中相同 rd 的旧值。
    issue(addi(1, 0, 99));
    issue(load(1, MEM_SIZE_BYTE, 'h1001));
    decode_payload = addi(3, 1, 1);
    decode_valid = 1;
    #1;
    assert (!decoded.ready && !forwarded.valid && executing.fire &&
            completion.payload.wb_req.wdata == 99)
      else $fatal(1, "EX load must block the older matching MEM result while draining");
    tick();
    // 响应无效时故意提供错误位和数据，不能丢失生产者身份或误判就绪。
    dmem.rsp_payload.error = 1;
    dmem.rsp_payload.rdata = 'h12345678;
    #1;
    assert (!decoded.ready && !completion.valid && wb.valid && wb.rd_addr == 1)
      else $fatal(1, "waiting MEM load must block matching WB despite invalid response bits");
    tick();
    dmem.rsp_payload.error = 0;
    dmem.rsp_payload.rdata = 'h0080ff00;
    #1;
    assert (!decoded.ready && completion.payload.wb_req.data_valid)
      else $fatal(1, "payload data_valid alone must not release a waiting load");
    dmem.rsp_valid = 1;
    #1;
    assert (decoded.fire && dmem.rsp_fire &&
            forwarded.payload.exec_data.rs1_value == 'hffffffff)
      else $fatal(1, "load response must release ID in the response cycle");
    tick();
    decode_valid = 0;
    dmem.rsp_valid = 0;
    assert (executing.valid && executed.payload.commit_ctx.wb_req.wdata == 0)
      else $fatal(1, "load consumer must execute immediately after the response cycle");
    drain();

    // rs1 等待 load 时，rs2 的 WB 离开后仍由 GPR 提供，不能捕获旧值。
    issue(addi(2, 0, 40));
    issue(load(1, MEM_SIZE_WORD, 'h2000));
    decode_payload = add(3, 1, 2);
    decode_valid = 1;
    tick();
    assert (!decoded.ready && wb.valid && wb.rd_addr == 2 &&
            forwarded.payload.exec_data.rs2_value == 40)
      else $fatal(1, "load wait must see an independent WB source");
    repeat (3) tick();
    assert (!decoded.ready && !wb.valid && forwarded.payload.exec_data.rs2_value == 40)
      else $fatal(1, "WB value must remain available from live GPR after WB leaves");
    dmem.rsp_valid = 1;
    dmem.rsp_payload.rdata = 50;
    #1;
    assert (decoded.fire && forwarded.payload.exec_data.rs1_value == 50 &&
            forwarded.payload.exec_data.rs2_value == 40)
      else $fatal(1, "load response must capture both current operands");
    tick();
    decode_valid = 0;
    dmem.rsp_valid = 0;
    assert (executed.payload.commit_ctx.wb_req.wdata == 90)
      else $fatal(1, "consumer must use load and committed WB");
    drain();

    // MEM 反压时 EX 结果仍可前递；已接收操作数保持稳定，容量释放时同拍替换。
    issue(load(5, MEM_SIZE_WORD, 'h3000));
    issue(add(3, 1, 2));
    decode_payload = addi(4, 3, 1);
    decode_valid = 1;
    repeat (3) begin
      #1;
      assert (!executing.ready && !decoded.ready && forwarded.valid &&
              forwarded.payload.exec_data.rs1_value == 90 &&
              executing.payload.exec_data.rs1_value == 50 &&
              executing.payload.exec_data.rs2_value == 40)
        else $fatal(1, "backpressure must preserve EX operands and available forwarding data");
      tick();
    end
    dmem.rsp_valid = 1;
    dmem.rsp_payload.rdata = 100;
    #1;
    assert (executing.fire && decoded.fire) else $fatal(1, "same-cycle replacement after MEM wait");
    tick();
    decode_valid = 0;
    dmem.rsp_valid = 0;
    assert (executed.payload.commit_ctx.wb_req.wdata == 91)
      else $fatal(1, "released consumer must use held EX result");
    drain();

    // EX 串行化等待时输出无效，但生产者仍须阻挡旧值。
    serialize_ready = 0;
    packet = addi(1, 0, 0);
    packet.ctrl.serialize = 1;
    packet.ctrl.wb_sel = WB_CSR;
    issue(packet);
    decode_payload = addi(3, 1, 1);
    decode_valid = 1;
    #1;
    assert (!executed.valid && !decoded.ready)
      else $fatal(1, "EX serialize wait must retain the producer without forwarding early");
    serialize_ready = 1;
    #1;
    assert (decoded.fire && forwarded.payload.exec_data.rs1_value == 77)
      else $fatal(1, "ready CSR result must forward from EX");
    tick();
    decode_valid = 0;
    assert (executed.payload.commit_ctx.wb_req.wdata == 78) else $fatal(1, "CSR result capture");
    drain();

    // 冲刷未接受的访存及其后的 EX/ID 事务，下一条指令读取当前 GPR。
    dmem.req_ready = 0;
    issue(load(5, MEM_SIZE_WORD, 'h4000));
    issue(addi(1, 0, 123));
    decode_payload = addi(3, 1, 1);
    decode_valid = 1;
    flush = 1;
    #1;
    assert (!forwarded.valid && !executing.valid && !memory.valid && !dmem.req_valid)
      else $fatal(1, "flush must suppress pending transactions immediately");
    tick();
    decode_valid = 0;
    flush = 0;
    issue(addi(3, 1, 1));
    assert (executed.payload.commit_ctx.wb_req.wdata == 78)
      else $fatal(1, "post-flush consumer must use GPR, not cancelled EX data");
    drain();

    $display("PASS: bubble-free EX forwarding, same-cycle load response, hazards, live GPR, backpressure and flush");
    $finish;
  end
endmodule
