// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

module wb_stage (
  // MEM -> WB 事务通道。WB 是当前五级流水中指令退休的位置。
  input logic mem_wb_valid_i,
  output logic mem_wb_ready_o,
  input mem_wb_bus_t mem_wb_bus_i,

  // 写回请求回送给 ID stage 内部的寄存器堆。
  output wb_req_bus_t wb_req_o,

  // 扁平化退休追踪总线。仿真环境优先观察该端口，而不是逐层访问嵌套
  // debug bus。
  output core_debug_bus_t core_debug_o
);

  logic wb_fire;

  // MEM/WB 寄存器已经是最后一道流水线边界。WB 不再增加状态，也不向
  // 上游施加额外背压；寄存器堆在 wb_fire 对应的时钟边沿完成写入。
  assign mem_wb_ready_o = 1'b1;
  assign wb_fire = mem_wb_valid_i && mem_wb_ready_o;

  always_comb begin
    wb_req_o = '0;
    core_debug_o = '0;

    if (wb_fire) begin
      // 保留 valid/data_valid 的事务语义；regfile 继续负责屏蔽 x0 和不完整
      // 的写回请求。用 wb_fire 门控可避免无效周期残留 payload 造成误写。
      wb_req_o = mem_wb_bus_i.wb_req;

      core_debug_o.valid = 1'b1;
      core_debug_o.pc = mem_wb_bus_i.debug.pc;
      core_debug_o.instr = mem_wb_bus_i.debug.instr;
      core_debug_o.gpr_we = mem_wb_bus_i.wb_req.valid && mem_wb_bus_i.wb_req.data_valid;
      core_debug_o.gpr_waddr = mem_wb_bus_i.wb_req.rd_addr;
      core_debug_o.gpr_wdata = mem_wb_bus_i.wb_req.wdata;
      core_debug_o.mem_valid = mem_wb_bus_i.debug.mem_valid;
      core_debug_o.mem_write = mem_wb_bus_i.debug.mem_write;
      core_debug_o.mem_size = mem_wb_bus_i.debug.mem_size;
      core_debug_o.mem_addr = mem_wb_bus_i.debug.mem_addr;
      core_debug_o.mem_wdata = mem_wb_bus_i.debug.mem_wdata;
      core_debug_o.redirect_valid = mem_wb_bus_i.debug.redirect_valid;
      core_debug_o.redirect_target_pc = mem_wb_bus_i.debug.redirect_target_pc;
    end
  end

endmodule
