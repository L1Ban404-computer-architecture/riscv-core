// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

// 将未经 lane 对齐的 rs2 数据转换为 CoreBus 写数据和 byte strobe。
module store_data_unit (
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
