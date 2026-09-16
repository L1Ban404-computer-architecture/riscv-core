// Flat test ports expose only the forwarding unit's public contract.
module forwarding_tb
  import riscv_common_pkg::*;
  import riscv_core_pkg::*;
(
  input logic clk_i, rst_ni, transaction_valid_i, execute_fire_i,
  input reg_addr_t rs1_addr_i, rs2_addr_i,
  input logic rs1_used_i, rs2_used_i,
  input word_t rs1_value_i, rs2_value_i,
  input logic ex_valid, ex_data_valid,
  input reg_addr_t ex_addr,
  input word_t ex_data,
  input logic mem_valid, mem_data_valid,
  input reg_addr_t mem_addr,
  input word_t mem_data,
  output word_t rs1_value_o, rs2_value_o,
  output logic stall_o
);
  writeback_if ex_wb ();
  writeback_if mem_wb ();
  assign ex_wb.payload = '{valid: ex_valid, data_valid: ex_data_valid,
                          rd_addr: ex_addr, wdata: ex_data};
  assign mem_wb.payload = '{valid: mem_valid, data_valid: mem_data_valid,
                           rd_addr: mem_addr, wdata: mem_data};
  forwarding_unit dut (
    .clk_i, .rst_ni, .transaction_valid_i, .execute_fire_i,
    .rs1_addr_i, .rs2_addr_i, .rs1_used_i, .rs2_used_i,
    .rs1_value_i, .rs2_value_i, .ex_wb, .mem_wb,
    .rs1_value_o, .rs2_value_o, .stall_o
  );
endmodule
