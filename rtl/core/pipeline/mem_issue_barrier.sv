// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// MEM 入口的组合屏障：WB 串行化事件存在时，阻止年轻事务继续执行。
// 这里只阻断握手；年轻事务由顶层的 WB 改道冲刷，提交行为仍由 WB 决定。
module mem_issue_barrier (
  ex_mem_if.consumer ex_mem,
  mem_wb_if.monitor mem_wb,
  ex_mem_if.producer result
);

  import riscv_core_pkg::*;

  logic serialize;

  // FENCE.I 与异常共用屏障，但保留独立提交标志，避免被解释为 trap。
  assign serialize = mem_wb.valid &&
      (classify_commit(mem_wb.payload.exception.valid, mem_wb.payload.commit) != COMMIT_NORMAL);

  assign result.payload = ex_mem.payload;
  assign result.valid = ex_mem.valid && !serialize;
  assign ex_mem.ready = result.ready && !serialize;

endmodule
