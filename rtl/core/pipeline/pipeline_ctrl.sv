// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 仲裁改道、串行化和副作用屏障；普通指令通过 ready/valid 推进。
module pipeline_ctrl
  import riscv_core_pkg::*;
(
  // 流水监视
  id_ex_if.monitor id_ex,
  ex_mem_if.monitor ex_mem,
  mem_wb_if.monitor mem_wb,
  redirect_if.monitor ex_redirect,
  redirect_if.monitor wb_redirect,

  // 控制输出
  output logic serialize_block_o,
  output logic serialize_ready_o,
  output logic mem_side_effect_block_o,
  redirect_if.producer resolved_redirect,
  output logic backend_flush_o
`ifndef SYNTHESIS
  , output riscv_debug_pkg::control_debug_payload_t debug_o
`endif
);

  // 精确异常要求“更老者获胜”。同周期 WB 提交异常与 EX 分支竞争时，
  // 必须采用 WB 目标，年轻分支随后由后端 flush 清除。
  // 分支只需要刷新前端；WB 的 trap/MRET 同时刷新前端和后端。
  // WB 更老，因此它的目标地址覆盖同周期 EX 产生的分支目标。
  assign resolved_redirect.valid = wb_redirect.valid || ex_redirect.valid;
  assign resolved_redirect.target_pc = wb_redirect.valid ? wb_redirect.target_pc :
      ex_redirect.target_pc;
  assign backend_flush_o = wb_redirect.valid;

  // CSR/SYSTEM 在 ID/EX 至 WB 期间构成串行屏障。它进入 EX 前先等待更老
  // EX/MEM 和 MEM/WB 排空，因此 CSR 读取无需专用前递。
  // 屏障存在期间禁止更年轻指令进入 ID/EX，异常同样需要保持精确顺序。
  assign serialize_block_o = (id_ex.valid &&
                              (id_ex.payload.ctrl.serialize || id_ex.payload.exception.valid)) ||
      (ex_mem.valid &&
       (ex_mem.payload.commit_ctx.commit.serialize || ex_mem.payload.commit_ctx.exception.valid)) ||
      (mem_wb.valid && (mem_wb.payload.commit.serialize || mem_wb.payload.exception.valid));
  // MEM 在响应完成前保持 EX/MEM；EX/MEM 排空也保证没有在途数据请求。
  // 只有更老的流水事务和待提交事务都已排空，当前屏障才允许进入 EX。
  assign serialize_ready_o = !ex_mem.valid && !mem_wb.valid;
  // WB 中的屏障尚未提交时，禁止更年轻访存发出可能可见的总线副作用。
  assign mem_side_effect_block_o = mem_wb.valid &&
      (mem_wb.payload.commit.serialize || mem_wb.payload.exception.valid);

`ifndef SYNTHESIS
  assign debug_o = '{redirect: resolved_redirect.valid, flush_backend: backend_flush_o};
`endif

endmodule
