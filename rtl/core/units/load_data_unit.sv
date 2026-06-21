// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

import riscv_core_pkg::*;

// 从 CoreBus 返回的完整字中选择目标 lane，并完成符号或零扩展。
module load_data_unit (
  input mem_size_e size_i,
  input logic sign_ext_i,
  input logic [1:0] addr_offset_i,
  input word_t rdata_i,
  output word_t load_data_o
);

  logic [4:0] shift_amount;
  word_t shifted_data;

  assign shift_amount = {addr_offset_i, 3'b000};
  assign shifted_data = rdata_i >> shift_amount;

  always_comb begin
    case (size_i)
      MEM_SIZE_BYTE: begin
        if (sign_ext_i) load_data_o = {{(XLen - 8) {shifted_data[7]}}, shifted_data[7:0]};
        else load_data_o = {{(XLen - 8) {1'b0}}, shifted_data[7:0]};
      end
      MEM_SIZE_HALF: begin
        if (sign_ext_i) load_data_o = {{(XLen - 16) {shifted_data[15]}}, shifted_data[15:0]};
        else load_data_o = {{(XLen - 16) {1'b0}}, shifted_data[15:0]};
      end
      MEM_SIZE_WORD: load_data_o = shifted_data;
      default: load_data_o = '0;
    endcase
  end

endmodule
