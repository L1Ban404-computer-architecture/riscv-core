// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 核对 JALR 的预测目标，等价于比较 (rs1+imm)&~1 与预测地址。
// 预测地址来自 BTB，bit 0 固定为零；加法按 XLEN 回绕。
// 用预测值反推各位所需进位，避免在完整加法后串接全宽比较。
module jalr_target_match
  import riscv_core_pkg::*;
(
  input word_t rs1_i,
  input word_t imm_i,
  input pc_t predicted_target_i,
  output logic match_o
);

  word_t required_carry, generated_carry;

  // sum[i] = rs1[i] ^ imm[i] ^ carry[i]；假设 sum 为预测地址，反求 carry。
  assign required_carry = rs1_i ^ imm_i ^ predicted_target_i;
  assign generated_carry = (rs1_i & imm_i) |
      ((rs1_i | imm_i) & required_carry);

  // JALR 丢弃 sum[0]，但 bit 0 的真实进位仍须进入 bit 1。
  // 其余各位检查所需进位与低一位产生的进位一致，最高位溢出自然丢弃。
  assign match_o = (required_carry[1] == (rs1_i[0] & imm_i[0])) &&
      (required_carry[XLen-1:2] == generated_carry[XLen-2:1]);

endmodule
