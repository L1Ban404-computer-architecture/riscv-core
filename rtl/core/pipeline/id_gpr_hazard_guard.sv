// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 临时的 ID 级 RAW 冒险屏障，不产生任何前递数据。
//
// 源寄存器仍有更老写入在途时，阻止 ID/EX 接收新事务，等写回完成后再从
// GPR 锁存新值。即使 EX/MEM 已有可前递结果，或 MEM/WB 本拍即可提交，也等待
// 冲突消失；load 的 data_valid=0 同样属于待写入，不能提前放行。
// ID/EX 也需检查：弹性寄存器允许同拍弹出/写入，其指令可能与当前译码指令
// 同拍分别进入 EX/MEM 和 ID/EX，只检查 EX/MEM、MEM/WB 会漏掉紧邻依赖。
//
// 此模块仅用于暂时规避 EX 数据冒险；原有 EX 前递逻辑保持不变。
// 恢复方式：将 riscv_core_impl 的 EnableTemporaryIdGprStall 设为 0。
// 永久移除时删除本模块、ID 中的临时实例/监视接口/握手门控，以及核心顶层
// 对应的临时参数和连线即可。
module id_gpr_hazard_guard
  import riscv_core_pkg::*;
(
  input logic transaction_valid_i,
  input reg_addr_payload_t sources_i,
  input logic id_ex_valid_i,
  input id_ex_payload_t id_ex_payload_i,
  ex_mem_if.monitor ex_mem,
  mem_wb_if.monitor mem_wb,
  output logic stall_o
);

  function automatic logic source_conflicts(input reg_addr_t rd_addr);
    return (rd_addr != ZeroReg) &&
        ((sources_i.rs1_used && (sources_i.rs1_addr == rd_addr)) ||
         (sources_i.rs2_used && (sources_i.rs2_addr == rd_addr)));
  endfunction

  assign stall_o = transaction_valid_i && (
      (id_ex_valid_i && id_ex_payload_i.ctrl.rd_write && !id_ex_payload_i.exception.valid &&
       source_conflicts(id_ex_payload_i.reg_addr.rd_addr)) ||
      (ex_mem.valid && ex_mem.payload.commit_ctx.wb_req.valid &&
       !ex_mem.payload.commit_ctx.exception.valid &&
       source_conflicts(ex_mem.payload.commit_ctx.wb_req.rd_addr)) ||
      (mem_wb.valid && mem_wb.payload.wb_req.valid && !mem_wb.payload.exception.valid &&
       source_conflicts(mem_wb.payload.wb_req.rd_addr)));

endmodule
