// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Store 数据整理单元，将目标 byte/half 复制到各 lane。
// EX 保证访问对齐，下游按 size 和地址生成写掩码，未选中的 lane 不产生写入。
module store_data_unit
  import riscv_core_pkg::*;
(
  // 访存属性与源数据
  input mem_size_e size_i,
  input word_t wdata_i,
  output word_t lane_data_o
);

  always_comb begin
    case (size_i)
      MEM_SIZE_BYTE: lane_data_o = {(XLen / 8) {wdata_i[7:0]}};
      MEM_SIZE_HALF: lane_data_o = {(XLen / 16) {wdata_i[15:0]}};
      default: lane_data_o = wdata_i;
    endcase
  end

endmodule
