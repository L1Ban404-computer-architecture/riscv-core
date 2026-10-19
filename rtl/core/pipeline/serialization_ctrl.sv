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

  // CSR 在 EX 读、WB 写；FENCE.I 在 EX 失效取指状态。两者保守等待旧事务
  // 排空，无需 CSR 地址比较或前递。MEM 在响应完成前保持 EX/MEM 有效，
  // 因而排空也保证没有在途数据请求。已知异常和 MRET 按普通握手推进。
  assign blocked = !upstream.payload.exception.valid &&
      ((upstream.payload.ctrl.csr_cmd != CSR_NONE) || upstream.payload.ctrl.fence_i) &&
      (ex_mem.valid || mem_wb.valid);

  // 同时屏蔽 valid 和 ready：上游保留事务，下游不会误执行，两侧 fire 始终一致。
  assign downstream.payload = upstream.payload;
  assign downstream.valid = upstream.valid && !blocked;
  assign upstream.ready = downstream.ready && !blocked;

endmodule
