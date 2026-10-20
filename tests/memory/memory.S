// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 覆盖所有合法 lane、符号扩展、窄写保护相邻字节和 Load 前递。
// a0 在失败时给出检查编号；适用于 RV32E/RV32I。
.section .text
.globl _start
.option norvc

.macro CHECK reg, value
  li t2, \value
  bne \reg, t2, fail
  addi a0, a0, 1
.endm

_start:
  li a0, 1
  li s0, TEST_RAM
  li s1, 0x807fff01
  sw s1, 0(s0)

  lb t0, 0(s0)
  CHECK t0, 1
  lb t0, 1(s0)
  CHECK t0, -1
  lb t0, 2(s0)
  CHECK t0, 127
  lb t0, 3(s0)
  CHECK t0, -128
  lbu t0, 0(s0)
  CHECK t0, 1
  lbu t0, 1(s0)
  CHECK t0, 255
  lbu t0, 2(s0)
  CHECK t0, 127
  lbu t0, 3(s0)
  CHECK t0, 128
  lh t0, 0(s0)
  CHECK t0, -255
  lh t0, 2(s0)
  CHECK t0, -32641
  lhu t0, 0(s0)
  CHECK t0, 0xff01
  lhu t0, 2(s0)
  CHECK t0, 0x807f
  lw t0, 0(s0)
  CHECK t0, 0x807fff01

  // 源寄存器的高位故意非零，检查窄写只修改指定字节。
  li s1, 0x123456aa
  sb s1, 0(s0)
  lw t0, 0(s0)
  CHECK t0, 0x807fffaa
  sb s1, 1(s0)
  lw t0, 0(s0)
  CHECK t0, 0x807faaaa
  sb s1, 2(s0)
  lw t0, 0(s0)
  CHECK t0, 0x80aaaaaa
  sb s1, 3(s0)
  lw t0, 0(s0)
  CHECK t0, 0xaaaaaaaa
  sh s1, 0(s0)
  lw t0, 0(s0)
  CHECK t0, 0xaaaa56aa
  sh s1, 2(s0)
  lw t0, 0(s0)
  CHECK t0, 0x56aa56aa

  // 正半字和负字节的扩展，以及 Load -> ALU 的相邻依赖。
  lh t0, 0(s0)
  addi t1, t0, 1
  CHECK t1, 0x56ab
  lb t0, 0(s0)
  addi t1, t0, 1
  CHECK t1, -85

  // Load -> Store 数据、Load -> Load 地址，不能错误前递有效地址。
  lw t0, 0(s0)
  sw t0, 4(s0)
  lw t1, 4(s0)
  CHECK t1, 0x56aa56aa
  sw s0, 8(s0)
  lw t0, 8(s0)
  lw t1, 0(t0)
  CHECK t1, 0x56aa56aa
  lw zero, 8(s0)
  addi t0, zero, 1
  CHECK t0, 1

#if CHECK_ACCESS_FAULTS
  // 错误响应仍须保留原始地址；年轻 Store 必须被异常改道取消。
  la t0, trap
  csrw mtvec, t0
  li a4, 0
  li a1, 5
  li a2, TEST_MTIME + 1
  la a3, 1f
  li t0, 0x12345678
1:
  lbu t0, 0(a2)
  sw zero, 0(s0)
  CHECK a4, 1
  CHECK t0, 0x12345678
  lw t0, 0(s0)
  CHECK t0, 0x56aa56aa

  // rd=x0 也必须访问并报告异常，不能把无写回误认为无访存。
  la a3, 1f
1:
  lbu zero, 0(a2)
  sw zero, 0(s0)
  CHECK a4, 2

  li a1, 7
  li a2, TEST_MTIME + 4
  la a3, 1f
1:
  sw s1, 0(a2)
  sw zero, 0(s0)
  CHECK a4, 3
  lw t0, 0(s0)
  CHECK t0, 0x56aa56aa

  // EX 拒绝未对齐 Store，异常地址不能被共享数据字段覆盖。
  li a1, 6
  addi a2, s0, 1
  la a3, 1f
1:
  sh s1, 0(a2)
  sw zero, 0(s0)
  CHECK a4, 4
  lw t0, 0(s0)
  CHECK t0, 0x56aa56aa
#endif

  li a0, 0
  ebreak

#if CHECK_ACCESS_FAULTS
.balign 4
trap:
  csrr t1, mcause
  bne t1, a1, fail
  csrr t1, mtval
  bne t1, a2, fail
  csrr t1, mepc
  bne t1, a3, fail
  addi a3, a3, 8
  csrw mepc, a3
  addi a4, a4, 1
  mret
#endif

fail:
  ebreak
  j fail
