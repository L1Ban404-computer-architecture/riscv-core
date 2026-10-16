// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Store 数据整理单元，生成按地址偏移对齐的写数据。
module store_data_unit
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  // 访存属性与源数据
  input mem_size_e size_i,
  input logic [1:0] addr_offset_i,
  input word_t wdata_i,
  output word_t aligned_wdata_o
);

  logic [4:0] shift_amount;

  assign shift_amount = {addr_offset_i, 3'b000};

  always_comb begin
    case (size_i)
      MEM_SIZE_BYTE, MEM_SIZE_HALF: aligned_wdata_o = wdata_i << shift_amount;
      default: aligned_wdata_o = wdata_i;
    endcase
  end

endmodule
