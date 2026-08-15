// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// Store 数据整理单元，生成按地址偏移对齐的写数据和字节选通。
module store_data_unit
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  // 访存属性与源数据
  input mem_size_e size_i,
  input logic [1:0] addr_offset_i,
  input word_t wdata_i,
  output word_t aligned_wdata_o,
  output byte_en_t wstrb_o
);

  logic [4:0] shift_amount;

  assign shift_amount = {addr_offset_i, 3'b000};

  always_comb begin
    case (size_i)
      MEM_SIZE_BYTE: begin
        aligned_wdata_o = wdata_i << shift_amount;
        wstrb_o = byte_en_t'(4'b0001 << addr_offset_i);
      end
      MEM_SIZE_HALF: begin
        aligned_wdata_o = wdata_i << shift_amount;
        wstrb_o = byte_en_t'(4'b0011 << addr_offset_i);
      end
      MEM_SIZE_WORD: begin
        aligned_wdata_o = wdata_i;
        wstrb_o = '1;
      end
      default: begin
        aligned_wdata_o = wdata_i;
        wstrb_o = '1;
      end
    endcase
  end

endmodule
