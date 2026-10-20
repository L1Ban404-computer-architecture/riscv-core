// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 对所有数据位、宽度和合法地址证明 Load 结果与 Store 有效字节的语义。
// 无效 Store lane 不参与比较，实际写入由 size/addr 生成的字节掩码决定。
module data_lanes
  import riscv_core_pkg::*;
(
  input mem_size_e size_i,
  input logic [1:0] offset_i,
  input logic sign_ext_i,
  input word_t rdata_i,
  input word_t wdata_i,
  output logic correct
);
  word_t loaded_data, store_data;
  word_t expected_load, shifted_read, shifted_write, mask;
  logic aligned;

  load_data_unit u_load (
    .size_i, .addr_offset_i(offset_i), .sign_ext_i, .rdata_i,
    .load_data_o(loaded_data)
  );
  store_data_unit u_store (
    .size_i, .wdata_i, .aligned_wdata_o(store_data)
  );

  assign shifted_read = rdata_i >> (8 * offset_i);
  assign shifted_write = wdata_i << (8 * offset_i);
  always_comb begin
    aligned = 1'b0;
    expected_load = '0;
    mask = '0;
    case (size_i)
      MEM_SIZE_BYTE: begin
        aligned = 1'b1;
        expected_load = sign_ext_i ? word_t'($signed(shifted_read[7:0])) :
                                    word_t'(shifted_read[7:0]);
        mask = 32'hff << (8 * offset_i);
      end
      MEM_SIZE_HALF: begin
        aligned = !offset_i[0];
        expected_load = sign_ext_i ? word_t'($signed(shifted_read[15:0])) :
                                    word_t'(shifted_read[15:0]);
        mask = 32'hffff << (8 * offset_i);
      end
      MEM_SIZE_WORD: begin
        aligned = offset_i == 0;
        expected_load = shifted_read;
        mask = '1;
      end
      default: ;
    endcase
  end
  assign correct = !aligned ||
      ((loaded_data == expected_load) && ((store_data & mask) == (shifted_write & mask)));
endmodule
