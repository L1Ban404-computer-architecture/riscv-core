// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

`include "common/assertions.svh"

module ex_stage #(
  parameter int unsigned MemOutstandingDepth = 2
) (
  input logic clk_i,
  input logic rst_ni,

  // ID -> EX 事务通道。进入 EX 的指令被视为已确认有效，不再被 redirect
  // 冲刷；若数据前递不可用，EX 通过 id_ex_ready_o 反压 ID。
  input logic id_ex_valid_i,
  output logic id_ex_ready_o,
  input id_ex_bus_t id_ex_bus_i,

  // MEM outstanding load 以及 MEM/WB 写回候选。另一路年龄最近的 EX/MEM
  // 候选由本 stage 内部保存。
  input wb_req_bus_t mem_pending_wb_req_i[MemOutstandingDepth],
  input wb_req_bus_t mem_wb_req_i,

  // EX -> IF redirect。该信号单向指向前端，只影响更年轻的 IF/ID 事务。
  output redirect_bus_t redirect_o,

  // EX -> MEM 事务通道。EX 负责形成访存请求、写回候选和 EX debug 信息。
  output logic ex_mem_valid_o,
  input logic ex_mem_ready_i,
  output ex_mem_bus_t ex_mem_bus_o
);

  word_t rs1_value;
  word_t rs2_value;
  word_t operand_a;
  word_t operand_b;
  word_t alu_result;
  word_t pc_plus_4;

  logic forward_stall;
  logic ex_execute_fire;
  logic ex_mem_input_valid;
  logic ex_mem_input_ready;

  wb_req_bus_t wb_req;
  wb_req_bus_t ex_mem_wb_req;
  mem_req_bus_t mem_req;
  ex_mem_bus_t executed_ex_mem_bus;

  always_comb begin
    ex_mem_wb_req = ex_mem_bus_o.wb_req;
    ex_mem_wb_req.valid = ex_mem_valid_o && ex_mem_bus_o.wb_req.valid;
  end

  forwarding_unit #(
    .MemOutstandingDepth(MemOutstandingDepth)
  ) u_forwarding_unit (
    .clk_i,
    .rst_ni,
    .transaction_valid_i(id_ex_valid_i),
    .execute_fire_i(ex_execute_fire),
    .reg_addr_i(id_ex_bus_i.reg_addr),
    .rs1_value_i(id_ex_bus_i.exec_data.rs1_value),
    .rs2_value_i(id_ex_bus_i.exec_data.rs2_value),
    .ctrl_i(id_ex_bus_i.ctrl),
    .ex_wb_req_i(ex_mem_wb_req),
    .mem_pending_wb_req_i,
    .mem_wb_req_i,
    .rs1_value_o(rs1_value),
    .rs2_value_o(rs2_value),
    .stall_o(forward_stall)
  );

  assign operand_a = (id_ex_bus_i.ctrl.op_a_sel == OP_A_PC) ? id_ex_bus_i.exec_data.pc : rs1_value;
  assign
      operand_b = (id_ex_bus_i.ctrl.op_b_sel == OP_B_IMM) ? id_ex_bus_i.exec_data.imm : rs2_value;

  alu u_alu (
    .alu_op_i(id_ex_bus_i.ctrl.alu_op),
    .operand_a_i(operand_a),
    .operand_b_i(operand_b),
    .result_o(alu_result)
  );

  branch_unit u_branch_unit (
    .execute_fire_i(ex_execute_fire),
    .illegal_instr_i(id_ex_bus_i.ctrl.illegal_instr),
    .branch_op_i(id_ex_bus_i.ctrl.branch_op),
    .rs1_value_i(rs1_value),
    .rs2_value_i(rs2_value),
    .alu_target_i(alu_result),
    .redirect_o
  );

  assign pc_plus_4 = id_ex_bus_i.exec_data.pc + word_t'(4);

  always_comb begin
    wb_req = '0;
    wb_req.valid = id_ex_bus_i.ctrl.rd_write && !id_ex_bus_i.ctrl.illegal_instr;
    wb_req.rd_addr = id_ex_bus_i.reg_addr.rd_addr;

    case (id_ex_bus_i.ctrl.wb_sel)
      WB_NONE: wb_req = '0;
      WB_ALU: begin
        wb_req.data_valid = 1'b1;
        wb_req.wdata = alu_result;
      end
      WB_MEM: begin
        wb_req.data_valid = 1'b0;
        wb_req.wdata = '0;
      end
      WB_PC4: begin
        wb_req.data_valid = 1'b1;
        wb_req.wdata = pc_plus_4;
      end
      default: wb_req = '0;
    endcase

    // x0 写入在这里提前消除，减少后续前递和写回端的无效比较活动。
    if (wb_req.rd_addr == ZeroReg) wb_req.valid = 1'b0;
  end

  always_comb begin
    mem_req = '0;
    mem_req.valid = (id_ex_bus_i.ctrl.mem_cmd != MEM_NONE) && !id_ex_bus_i.ctrl.illegal_instr;
    mem_req.write = (id_ex_bus_i.ctrl.mem_cmd == MEM_STORE);
    mem_req.size = id_ex_bus_i.ctrl.mem_size;
    mem_req.sign_ext = id_ex_bus_i.ctrl.mem_sign_ext;
    mem_req.addr = alu_result;
    // 保留未经 lane 对齐的 rs2 数据，移位和 byte enable 生成放在 MEM。
    mem_req.wdata = rs2_value;
  end

  // 前递数据未就绪时不允许当前 ID/EX 事务进入 EX/MEM 寄存器。
  assign ex_mem_input_valid = id_ex_valid_i && !forward_stall;
  assign id_ex_ready_o = ex_mem_input_ready && !forward_stall;
  assign ex_execute_fire = ex_mem_input_valid && ex_mem_input_ready;

  always_comb begin
    executed_ex_mem_bus = '0;
    executed_ex_mem_bus.mem_req = mem_req;
    executed_ex_mem_bus.wb_req = wb_req;
    executed_ex_mem_bus.debug.id_debug = id_ex_bus_i.debug;
    executed_ex_mem_bus.debug.redirect = redirect_o;
    executed_ex_mem_bus.debug.alu_result = alu_result;
  end

  // EX/MEM 与 ID/EX 一样使用单入口双向握手寄存器。满载且 MEM ready 时
  // 可以同拍 pop/push，不会在连续指令之间插入气泡。
  stream_register #(
    .T(ex_mem_bus_t)
  ) u_ex_mem_register (
    .clk_i,
    .rst_ni,
    .clr_i(1'b0),
    .valid_i(ex_mem_input_valid),
    .ready_o(ex_mem_input_ready),
    .data_i(executed_ex_mem_bus),
    .valid_o(ex_mem_valid_o),
    .ready_i(ex_mem_ready_i),
    .data_o(ex_mem_bus_o)
  );

  // verilog_format: off
  `ASSERT_STABLE(
    ExMemStable,
    ex_mem_valid_o,
    ex_mem_ready_i,
    ex_mem_bus_o,
    ex_mem_bus_t'(0),
    clk_i,
    !rst_ni,
    "EX/MEM payload must remain stable while valid is waiting for ready."
  )

  `ASSERT(
    ExMemValidStable,
    ex_mem_valid_o && !ex_mem_ready_i |=> ex_mem_valid_o,
    clk_i,
    !rst_ni,
    "EX/MEM valid must remain asserted until ready."
  )
  // verilog_format: on
endmodule
