// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

module pipeline_tb;
  import riscv_core_pkg::*;
  logic clk = 0, rst_n = 0;
  id_ex_if instruction ();
  ex_mem_if executed ();
  redirect_if correction ();
  branch_update_if training ();
  logic older_inflight;
  if_id_if decode_input ();
  id_ex_if decoded ();
  id_ex_if decode_latched ();
  gpr_read_if registers ();
  id_stage decode_dut (.if_id(decode_input), .result(decoded), .gpr_read(registers));
  stream_register #(.T(id_ex_payload_t)) decode_register (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .valid_i(decoded.valid), .ready_o(decoded.ready), .data_i(decoded.payload),
    .valid_o(decode_latched.valid), .ready_i(decode_latched.ready), .data_o(decode_latched.payload)
  );
  assign registers.rs1_value = '0;
  assign registers.rs2_value = '0;
  ex_stage execute_dut (
    .id_ex(instruction), .older_inflight_i(older_inflight),
    .redirect(correction), .branch_update(training), .result(executed)
  );

  redirect_if fetch_ex_redirect ();
  redirect_if fetch_wb_redirect ();
  branch_update_if fetch_training ();
  core_bus_if imem ();
  if_id_if fetched ();
  logic flush, invalidate;
  if_id_payload_t saved;
  if_stage fetch_dut (
    .clk_i(clk), .rst_ni(rst_n), .boot_pc_i(32'h30000100),
    .ex_redirect(fetch_ex_redirect), .wb_redirect(fetch_wb_redirect),
    .branch_update(fetch_training), .imem_flush_o(flush), .imem_invalidate_o(invalidate),
    .imem, .result(fetched)
  );

  task automatic tick;
    #1; clk = 1; #1; clk = 0; #1;
  endtask

  task automatic require(input logic condition, input string message);
    if (!condition) $fatal(1, "%s", message);
  endtask

  initial begin
    older_inflight = 0;
    decode_input.valid = 0;
    decode_input.payload = '0;
    decode_latched.ready = 0;
    instruction.valid = 1;
    instruction.payload = '0;
    executed.ready = 1;
    fetch_ex_redirect.valid = 0;
    fetch_ex_redirect.payload = '0;
    fetch_wb_redirect.valid = 0;
    fetch_wb_redirect.payload = '0;
    fetch_training.valid = 0;
    fetch_training.payload = '0;
    imem.req_ready = 0;
    imem.rsp_valid = 0;
    imem.rsp_payload = '0;
    fetched.ready = 0;
    tick();
    rst_n = 1;

    // ID 对真实 B/J 编码预计算目标，并由 ID/EX 在背压期间保存。
    decode_input.payload.meta.pc = 32'h30000100;
    decode_input.payload.meta.instr = 32'h100000ef; // jal ra, +256
    #1;
    require(!decoded.payload.exception.valid &&
            decoded.payload.exec_data.direct_target == 32'h30000200 &&
            decoded.payload.exec_data.imm == 32'h100, "ID precomputes JAL target and retains immediate");
    decode_input.payload.meta.instr = 32'hfe0008e3; // beq zero, zero, -16
    #1;
    require(!decoded.payload.exception.valid &&
            decoded.payload.exec_data.direct_target == 32'h300000f0, "ID signed B immediate");
    decode_input.payload.meta.pc = 32'hfffffff0;
    decode_input.payload.meta.instr = 32'h030000ef; // jal ra, +48
    #1;
    require(decoded.payload.exec_data.direct_target == 32'h20, "ID target wraps at XLEN");
    decode_input.payload.meta.pc = 32'h30000100;
    decode_input.payload.meta.instr = 32'h10000063; // beq zero, zero, +256
    decode_input.payload.meta.prediction = '{taken: 1'b1, target: btb_target_t'(16'h200 >> 1)};
    decode_input.valid = 1;
    tick();
    decode_input.valid = 0;
    decode_input.payload.meta.pc = 32'h40000000;
    #1;
    require(decode_latched.valid && decode_latched.payload.exec_data.direct_target == 32'h30000200,
            "ID/EX retains original target while ID input changes");
    instruction.payload = decode_latched.payload;

    // 正确方向、错误目标仍须纠错；完整 PC 的高位也必须参与比较。
    instruction.payload.meta.pc = 32'h30000100;
    instruction.payload.meta.prediction = '{taken: 1'b1, target: btb_target_t'(16'h200 >> 1)};
    instruction.payload.ctrl.branch_op = BR_BEQ;
    instruction.payload.ctrl.alu_op = ALU_ADD;
    instruction.payload.ctrl.op_a_sel = OP_A_PC;
    instruction.payload.ctrl.op_b_sel = OP_B_IMM;
    instruction.payload.exec_data.imm = 32'h100;
    instruction.payload.exec_data.direct_target = 32'h30000200;
    #1;
    require(!correction.valid && training.valid && training.payload.taken,
            "correct branch prediction must train without redirect");
    require(training.payload.tag == btb_tag_t'(32'h100 >> 2) &&
            training.payload.target == btb_target_t'(32'h200 >> 1), "compact training payload");
    // 故意改变 EX 的立即数及 ALU 控制，B/J 只使用锁存的 ID 目标。
    instruction.payload.exec_data.imm = 32'h12345678;
    instruction.payload.ctrl.alu_op = ALU_XOR;
    instruction.payload.ctrl.op_a_sel = OP_A_RS1;
    instruction.payload.ctrl.op_b_sel = OP_B_RS2;
    #1;
    require(!correction.valid && training.payload.target == btb_target_t'(32'h200 >> 1),
            "B/J target and training use ID snapshot independently of EX immediate/ALU");
    instruction.payload.meta.prediction.target = btb_target_t'(16'h300 >> 1);
    #1;
    require(correction.valid && correction.payload.target_pc == 32'h30000200,
            "taken branch with aliased wrong target must redirect");
    instruction.payload.meta.prediction.target = btb_target_t'(16'h200 >> 1);
    instruction.payload.exec_data.imm = 32'h10100;
    instruction.payload.exec_data.direct_target = 32'h30010200;
    #1;
    require(correction.valid && correction.payload.target_pc == 32'h30010200,
            "cross-64KiB target must compare high bits");

    // 普通指令假跳转，以及 JALR 命中别名后的目标纠错。
    instruction.payload.ctrl.branch_op = BR_NONE;
    #1;
    require(correction.valid && correction.payload.target_pc == 32'h30000104 && !training.valid,
            "ordinary instruction alias must recover sequential PC without training");
    instruction.payload.ctrl.branch_op = BR_JALR;
    instruction.payload.ctrl.alu_op = ALU_ADD;
    instruction.payload.ctrl.op_a_sel = OP_A_RS1;
    instruction.payload.ctrl.op_b_sel = OP_B_IMM;
    instruction.payload.exec_data.rs1_value = 32'h80000100;
    instruction.payload.exec_data.imm = 32'h101;
    #1;
    require(correction.valid && correction.payload.target_pc == 32'h80000200 && !training.valid,
            "JALR retains EX ALU rs1+imm and clears bit 0 without training");
    instruction.payload.exec_data.imm = 32'h103;
    #1;
    require(executed.payload.commit_ctx.exception.valid &&
            executed.payload.commit_ctx.exception.tval == 32'h80000202 && !correction.valid,
            "JALR retains bit 1 for IALIGN exception after clearing bit 0");
    instruction.payload.ctrl.branch_op = BR_JAL;
    instruction.payload.exec_data.rs1_value = 0;
    instruction.payload.exec_data.imm = 32'h10100;
    instruction.payload.exec_data.direct_target = 32'h30010200;
    #1;
    require(training.valid && training.payload.kind == BTB_JAL, "JAL training classification");
    instruction.payload.meta.pc = 32'hfffffff0;
    instruction.payload.exec_data.imm = 32'h30;
    instruction.payload.exec_data.direct_target = 32'h20;
    #1;
    require(correction.valid && correction.payload.target_pc == 32'h20 &&
            training.payload.target == btb_target_t'(32'h20 >> 1), "target addition wraps at XLEN");
    instruction.payload.meta.pc = 32'h30000100;
    instruction.payload.exec_data.imm = 32'hfffffff0;
    instruction.payload.exec_data.direct_target = 32'h300000f0;
    #1;
    require(correction.valid && correction.payload.target_pc == 32'h300000f0 &&
            training.payload.target == btb_target_t'(32'hf0 >> 1), "negative branch immediate");

    instruction.payload.ctrl.branch_op = BR_BEQ;
    instruction.payload.exec_data.imm = 32'h102;
    instruction.payload.exec_data.direct_target = 32'h30000202;
    instruction.payload.exec_data.rs2_value = 1;
    instruction.payload.meta.prediction = '0;
    #1;
    require(training.valid && !training.payload.taken && !correction.valid &&
            training.payload.target[1] == 1'b1,
            "not-taken unaligned branch must preserve encoded target bit 1");
    instruction.payload.exec_data.rs2_value = 0;
    #1;
    require(executed.payload.commit_ctx.exception.valid && !correction.valid && !training.valid,
            "taken unaligned branch must trap without training/redirect");
    instruction.payload.exec_data.imm = 32'h100;
    instruction.payload.exec_data.direct_target = 32'h30000200;
    instruction.payload.exception.valid = 1;
    #1;
    require(!correction.valid && !training.valid, "upstream exception suppresses training");
    instruction.payload.exception.valid = 0;
    executed.ready = 0;
    #1;
    require(!correction.valid && !training.valid, "backpressure suppresses repeated training");
    executed.ready = 1;
    instruction.valid = 0;
    #1;
    require(!correction.valid && !training.valid, "bubble suppresses training");
    instruction.valid = 1;
    instruction.payload.ctrl.branch_op = BR_NONE;
    instruction.payload.ctrl.fence_i = 1;
    older_inflight = 1;
    #1;
    require(!instruction.ready && !correction.valid, "FENCE.I waits for older instructions");
    older_inflight = 0;
    #1;
    require(correction.valid && correction.payload.imem_invalidate && !training.valid,
            "FENCE.I invalidates and redirects once ready");

    // 请求被接受时锁存预测；IF 直连 ID，后续训练和背压不能修改在途快照。
    fetch_training.valid = 1;
    fetch_training.payload = '{tag: btb_tag_t'(32'h100 >> 2),
        target: btb_target_t'(32'h200 >> 1), kind: BTB_BRANCH, taken: 1'b1};
    tick();
    tick();
    require(imem.req_payload.addr == 32'h30000100, "stalled request PC stays unchanged");
    fetch_training.valid = 0;
    imem.req_ready = 1;
    tick();
    require(imem.req_payload.addr == 32'h30000200, "accepted request follows Bimodal target");
    imem.req_ready = 0;
    fetch_training.valid = 1;
    fetch_training.payload.target = btb_target_t'(32'h300 >> 1);
    tick();
    fetch_training.valid = 0;
    imem.rsp_valid = 1;
    imem.rsp_payload.rdata = 32'h13;
    #1;
    require(fetched.valid && fetched.payload.meta.pc == 32'h30000100 &&
            fetched.payload.meta.prediction.taken &&
            btb_target_pc(fetched.payload.meta.pc, fetched.payload.meta.prediction.target) ==
                32'h30000200, "in-flight snapshot survives BTB replacement/training");
    saved = fetched.payload;
    repeat (3) begin
      tick();
      require(fetched.valid && fetched.payload == saved,
              "direct IF-to-ID backpressure preserves request and prediction snapshot");
    end
    // 当前 BTB 已被改写成 0x300；EX 必须使用随指令保存的旧目标 0x200。
    instruction.payload = '0;
    instruction.payload.meta = fetched.payload.meta;
    instruction.payload.ctrl.branch_op = BR_BEQ;
    instruction.payload.ctrl.alu_op = ALU_ADD;
    instruction.payload.ctrl.op_a_sel = OP_A_PC;
    instruction.payload.ctrl.op_b_sel = OP_B_IMM;
    instruction.payload.exec_data.imm = 32'h100;
    instruction.payload.exec_data.direct_target = 32'h30000200;
    #1;
    require(!correction.valid, "EX uses saved prediction rather than current BTB target");
    fetched.ready = 1;
    tick();
    imem.rsp_valid = 0;
    #1;
    require(!fetched.valid, "direct response consumed once");

    // 失效当拍取消回应与预测；同时到达的训练不能复活旧表项/BHT。
    fetch_training.valid = 1;
    fetch_ex_redirect.valid = 1;
    fetch_ex_redirect.payload = '{target_pc: 32'h30000100, imem_invalidate: 1'b1};
    #1;
    require(invalidate && !fetched.valid,
            "FENCE.I cancels old response and prediction snapshot immediately");
    tick();
    fetch_ex_redirect.valid = 0;
    fetch_training.valid = 0;
    imem.req_ready = 1;
    tick();
    require(imem.req_payload.addr == 32'h30000104, "invalidation wins over simultaneous training");
    imem.req_ready = 0;
    $display("PASS: ID B/J targets and ID/EX snapshots; EX saved prediction alias/target/high-bits/JALR/exception/backpressure/FENCE.I; direct IF-to-ID snapshots/backpressure");
    $finish;
  end
endmodule
