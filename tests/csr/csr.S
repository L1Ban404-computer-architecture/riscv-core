// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

// 仅使用 RV32E 寄存器；a0 保留失败用例编号，a5 统计异常次数。
// 无运行时依赖，失败/成功均按 runner 的 a0 + EBREAK 约定结束。
.section .text
.option norvc
.option norelax
.global _start

.macro CHECK reg, value
  li t2, \value
  bne \reg, t2, fail
.endm

.macro CHECK_CSR csr, value
  csrr t1, \csr
  CHECK t1, \value
.endm

// 读取实际指令编码作为非法指令的预期 mtval；不占用 t0 源寄存器。
.macro ILLEGAL instruction
  li s0, 2
  li a3, 4
  la a4, 1f
  lw s1, 0(a4)
1:
  \instruction
.endm

_start:
  li a0, 1
  li a5, 0
  la t0, trap
  csrw mtvec, t0

  // 连续访问同一 CSR，无源寄存器依赖来掩盖 CSR 顺序错误。
  li a1, 0x12345678
  li a3, 0x00000080
  li a4, 0x00000008
  csrw mtval, a1
  csrrs a2, mtval, a3
  csrrc a3, mtval, a4
  CHECK a2, 0x12345678
  CHECK a3, 0x123456f8
  CHECK_CSR mtval, 0x123456f0

  li a0, 2
  csrrwi a1, mtval, 3
  csrrsi a2, mtval, 16
  csrrci a3, mtval, 1
  CHECK a1, 0x123456f0
  CHECK a2, 3
  CHECK a3, 19
  CHECK_CSR mtval, 18

  // rd=rs1：先保存源值，再返回旧值；rd=x0 仍须执行 CSR 写入。
  li a0, 3
  li a1, 0x87654321
  csrrw a1, mtval, a1
  CHECK a1, 18
  CHECK_CSR mtval, 0x87654321
  csrrw zero, mtval, zero
  CHECK_CSR mtval, 0
  csrrwi zero, mtval, 31
  csrrwi a1, mtval, 0
  CHECK a1, 31
  CHECK_CSR mtval, 0

  // 零掩码读、值为零的非 x0 源，以及只读 CSR 的合法读。
  li a0, 4
  li t0, 0
  csrrs a1, mvendorid, zero
  csrrc a2, mvendorid, zero
  csrrsi a3, marchid, 0
  csrrci a4, marchid, 0
  CHECK a1, 0x79737978
  CHECK a2, 0x79737978
  CHECK a3, 25080230
  CHECK a4, 25080230
  csrrs zero, mtval, t0
  csrrc zero, mtval, t0
  CHECK_CSR mtval, 0

  // ALU -> CSR -> ALU/store 与 load -> CSR；检查未就绪结果不会错误前递。
  li a0, 5
  li a1, 40
  addi a1, a1, 2
  csrw mtval, a1
  csrr a2, mtval
  addi a3, a2, 1
  CHECK a3, 43
  li a4, TEST_RAM
  csrr a2, mtval
  sw a2, 0(a4)
  lw a1, 0(a4)
  csrw mcause, a1
  CHECK_CSR mcause, 42

  // 掩码/WARL 字段与错误路径取消。
  li a0, 6
  li t0, -4 + 3 * CHECK_MEPC_WARL
  csrw mepc, t0
  CHECK_CSR mepc, 0xfffffffc
  li t0, -1
  csrw mstatus, t0
  CHECK_CSR mstatus, 0x1888
  csrw mtvec, t0
  CHECK_CSR mtvec, 0xfffffffc
  la t0, trap
  csrw mtvec, t0
  beq zero, zero, 1f
  csrw mtvec, zero
1:
  csrr t1, mtvec
  bne t0, t1, fail

  // 软件写 mepc 紧接 MRET，返回后必须看到更新后的 mstatus。
  li a0, 7
  la t0, returned
  csrw mepc, t0
  mret
  j fail
returned:
  CHECK_CSR mstatus, 0x1888

  // 非 x0 源即使值为零，也必须对只读 CSR 报非法写。
  li a0, 8
  li t0, 0
  ILLEGAL "csrrs a1, mvendorid, t0"
  li t0, 0
  ILLEGAL "csrrc a1, marchid, t0"
  ILLEGAL "csrrw zero, mvendorid, zero"
  ILLEGAL "csrrwi zero, marchid, 0"
  ILLEGAL "csrrsi zero, mvendorid, 1"
  ILLEGAL "csrrci zero, marchid, 1"

  // 未实现的可写地址、只读地址，以及非法 SYSTEM funct3。
  li a0, 9
  ILLEGAL "csrrs a1, 0x340, zero"
  ILLEGAL "csrrs a1, 0xfff, zero"
  ILLEGAL ".word 0x30004073"
  CHECK a5, 9

  // ECALL 保存现场，MRET 恢复 MIE；紧跟异常的年轻指令不能提前写 CSR。
  li a0, 10
  li s0, 11
  li s1, 0
  li a3, 8
  la a4, 1f
1:
  ecall
  csrw mtvec, zero
  CHECK a5, 10
  CHECK_CSR mstatus, 0x1888

  // 跳转目标未对齐：EX 可以推测改道，但 WB 必须报告原指令的异常，
  // 不得写入链接寄存器；trap 返回后的取指也必须从正确地址恢复。
  li a0, 11
  li a1, 123
  li s0, 0
  li a3, 4
  la a4, 1f
  addi s1, a4, 2
1:
  jal a1, .+2
  CHECK a1, 123
  CHECK a5, 11

  li a0, 12
  la a4, 1f
  addi s1, a4, 2
  addi t0, a4, 3
1:
  jalr a1, t0, 0
  CHECK a1, 123
  CHECK a5, 12

  li a0, 13
  la a4, 1f
  addi s1, a4, 2
1:
  beq zero, zero, .+2
  CHECK a5, 13
  bne zero, zero, .+2
  CHECK a5, 13

  // 旧 load 在 EX 报异常；年轻 store/CSR 必须被 WB 冲刷，不能提前产生副作用。
  li a0, 14
  li t0, TEST_RAM
  li a1, 0x13579bdf
  sw a1, 0(t0)
  li s0, 4
  addi s1, t0, 1
  li a3, 12
  la a4, 1f
1:
  lw a1, 1(t0)
  sw zero, 0(t0)
  csrw mtvec, zero
  CHECK a1, 0x13579bdf
  li t0, TEST_RAM
  lw a1, 0(t0)
  CHECK a1, 0x13579bdf
  CHECK a5, 14

  li a0, 0
  ebreak
  j fail

// 检查原因、PC、mtval 和中断使能栈；a3 指定跳过故障指令及年轻事务的字节数。
.balign 4
trap:
  csrr t0, mcause
  bne t0, s0, fail
  csrr t0, mepc
  bne t0, a4, fail
  csrr t0, mtval
  bne t0, s1, fail
  csrr t0, mtvec
  la t1, trap
  bne t0, t1, fail
  CHECK_CSR mstatus, 0x1880
  addi a5, a5, 1
  add a4, a4, a3
  csrw mepc, a4
  mret

fail:
  ebreak
  j fail
