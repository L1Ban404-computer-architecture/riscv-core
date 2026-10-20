// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// ID/EX 到 EX 的组合握手过滤器，不保存事务或新增流水级。
module serialization_ctrl
  import riscv_core_pkg::*;
(
  id_ex_if.consumer upstream,
  id_ex_if.producer downstream,
  ex_mem_if.monitor ex_mem,
  mem_wb_if.monitor mem_wb
);

  logic blocked;

  // FENCE.I 在 EX 失效取指状态前等待旧事务排空，确保没有在途数据请求。
  // CSR 统一在 WB 按程序顺序读改写，无需 EX 串行化或 CSR 前递。
  assign blocked = !upstream.payload.exception.valid && upstream.payload.ctrl.fence_i &&
      (ex_mem.valid || mem_wb.valid);

  // 同时屏蔽 valid 和 ready：上游保留事务，下游不会误执行，两侧 fire 始终一致。
  assign downstream.payload = upstream.payload;
  assign downstream.valid = upstream.valid && !blocked;
  assign upstream.ready = downstream.ready && !blocked;

endmodule
