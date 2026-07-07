# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import NextTimeStep, RisingEdge, Timer


ALU_ADD, ALU_SUB, ALU_SLL = 0, 1, 2
ALU_SRA, ALU_PASS_B = 7, 10
OP_A_RS1, OP_A_PC = 0, 1
OP_B_RS2, OP_B_IMM = 0, 1
BR_NONE, BR_JAL, BR_JALR, BR_BEQ = 0, 1, 2, 3
MEM_NONE, MEM_LOAD, MEM_STORE = 0, 1, 2
MEM_BYTE, MEM_HALF, MEM_WORD = 0, 1, 2
WB_NONE, WB_ALU, WB_MEM, WB_PC4 = 0, 1, 2, 3


def encode_r(funct7, rs2, rs1, funct3, rd, opcode=0x33):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def encode_i(imm, rs1, funct3, rd, opcode=0x13):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def encode_s(imm, rs2, rs1, funct3):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((imm & 0x1F) << 7) | 0x23


def encode_b(imm, rs2, rs1, funct3):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63


async def reset_dut(dut):
    dut.rst_ni.value = 0
    dut.if_id_valid_i.value = 0
    dut.if_id_pc_i.value = 0
    dut.if_id_instr_i.value = 0
    dut.id_ex_ready_i.value = 1
    dut.wb_valid_i.value = 0
    dut.wb_data_valid_i.value = 0
    dut.wb_rd_addr_i.value = 0
    dut.wb_wdata_i.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()


async def wb_write(dut, rd, value):
    dut.wb_valid_i.value = 1
    dut.wb_data_valid_i.value = 1
    dut.wb_rd_addr_i.value = rd
    dut.wb_wdata_i.value = value
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    dut.wb_valid_i.value = 0
    dut.wb_data_valid_i.value = 0


async def push(dut, instr, pc=0x80000000):
    assert int(dut.if_id_ready_o.value) == 1
    dut.if_id_instr_i.value = instr
    dut.if_id_pc_i.value = pc
    dut.if_id_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    dut.if_id_valid_i.value = 0
    assert int(dut.id_ex_valid_o.value) == 1


async def consume(dut):
    dut.id_ex_ready_i.value = 1
    dut.if_id_valid_i.value = 0
    await RisingEdge(dut.clk_i)
    await NextTimeStep()


@cocotb.test()
async def decode_registers_immediates_and_wb_bypass(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    await wb_write(dut, 1, 0x11223344)
    await wb_write(dut, 2, 0x55667788)
    await push(dut, encode_r(0, 2, 1, 0, 3))
    assert int(dut.id_ex_rs1_addr_o.value) == 1
    assert int(dut.id_ex_rs2_addr_o.value) == 2
    assert int(dut.id_ex_rd_addr_o.value) == 3
    assert int(dut.id_ex_rs1_value_o.value) == 0x11223344
    assert int(dut.id_ex_rs2_value_o.value) == 0x55667788
    assert int(dut.id_ex_alu_op_o.value) == ALU_ADD
    assert int(dut.id_ex_wb_sel_o.value) == WB_ALU
    assert int(dut.id_ex_rd_write_o.value) == 1
    assert int(dut.id_ex_illegal_instr_o.value) == 0
    await consume(dut)

    await push(dut, encode_i(-4, 1, 0, 4))
    assert int(dut.id_ex_imm_o.value) == 0xFFFFFFFC
    assert int(dut.id_ex_op_b_sel_o.value) == OP_B_IMM
    await consume(dut)

    # A WB value presented on the capture edge must be visible to ID immediately.
    dut.wb_valid_i.value = 1
    dut.wb_data_valid_i.value = 1
    dut.wb_rd_addr_i.value = 5
    dut.wb_wdata_i.value = 0xA5A55A5A
    await push(dut, encode_r(0, 0, 5, 0, 6))
    assert int(dut.id_ex_rs1_value_o.value) == 0xA5A55A5A
    assert int(dut.id_ex_rs2_value_o.value) == 0
    dut.wb_valid_i.value = 0
    dut.wb_data_valid_i.value = 0
    await consume(dut)

    # Writes to x0 are discarded.
    await wb_write(dut, 0, 0xFFFFFFFF)
    await push(dut, encode_r(0, 0, 0, 0, 1))
    assert int(dut.id_ex_rs1_value_o.value) == 0
    assert int(dut.id_ex_rs2_value_o.value) == 0


@cocotb.test()
async def control_decode_representative_rv32i_classes(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    cases = [
        # instr, expected fields
        ((0xABCDE << 12) | (7 << 7) | 0x37,
         dict(alu=ALU_PASS_B, opa=OP_A_RS1, opb=OP_B_IMM, wb=WB_ALU, imm=0xABCDE000)),
        ((0x12345 << 12) | (8 << 7) | 0x17,
         dict(alu=ALU_ADD, opa=OP_A_PC, opb=OP_B_IMM, wb=WB_ALU, imm=0x12345000)),
        (encode_b(-16, 2, 1, 0),
         dict(alu=ALU_ADD, opa=OP_A_PC, opb=OP_B_IMM, branch=BR_BEQ, imm=0xFFFFFFF0)),
        (encode_i(12, 1, 0b100, 3, 0x03),
         dict(mem=MEM_LOAD, size=MEM_BYTE, sign=0, wb=WB_MEM, imm=12)),
        (encode_s(-8, 2, 1, 0b001),
         dict(mem=MEM_STORE, size=MEM_HALF, imm=0xFFFFFFF8)),
        (encode_i((0b0100000 << 5) | 3, 1, 0b101, 4),
         dict(alu=ALU_SRA, wb=WB_ALU)),
        (encode_r(0b0100000, 2, 1, 0, 3),
         dict(alu=ALU_SUB, wb=WB_ALU)),
        ((4 << 7) | 0x6F,
         dict(opa=OP_A_PC, opb=OP_B_IMM, branch=BR_JAL, wb=WB_PC4)),
        (encode_i(20, 1, 0, 4, 0x67),
         dict(opa=OP_A_RS1, opb=OP_B_IMM, branch=BR_JALR, wb=WB_PC4, imm=20)),
    ]

    for index, (instr, expected) in enumerate(cases):
        await push(dut, instr, 0x80000000 + 4 * index)
        assert int(dut.id_ex_illegal_instr_o.value) == 0
        if "alu" in expected: assert int(dut.id_ex_alu_op_o.value) == expected["alu"]
        if "opa" in expected: assert int(dut.id_ex_op_a_sel_o.value) == expected["opa"]
        if "opb" in expected: assert int(dut.id_ex_op_b_sel_o.value) == expected["opb"]
        if "branch" in expected: assert int(dut.id_ex_branch_op_o.value) == expected["branch"]
        if "mem" in expected: assert int(dut.id_ex_mem_cmd_o.value) == expected["mem"]
        if "size" in expected: assert int(dut.id_ex_mem_size_o.value) == expected["size"]
        if "sign" in expected: assert int(dut.id_ex_mem_sign_ext_o.value) == expected["sign"]
        if "wb" in expected: assert int(dut.id_ex_wb_sel_o.value) == expected["wb"]
        if "imm" in expected: assert int(dut.id_ex_imm_o.value) == expected["imm"]
        await consume(dut)

    # Reserved shift encoding and unsupported SYSTEM instructions must not write rd.
    for instr in (encode_i((0b0010000 << 5) | 1, 1, 0b001, 3), 0x00000073):
        await push(dut, instr)
        assert int(dut.id_ex_illegal_instr_o.value) == 1
        assert int(dut.id_ex_rd_write_o.value) == 0
        assert int(dut.id_ex_wb_sel_o.value) == WB_NONE
        await consume(dut)


@cocotb.test()
async def elastic_register_backpressure_replacement_and_drain(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    first = encode_i(1, 0, 0, 1)
    second = encode_i(2, 0, 0, 2)
    await push(dut, first, 0x1000)

    dut.id_ex_ready_i.value = 0
    dut.if_id_valid_i.value = 1
    dut.if_id_instr_i.value = second
    dut.if_id_pc_i.value = 0x1004
    await Timer(1, unit="ns")
    for _ in range(3):
        assert int(dut.if_id_ready_o.value) == 0
        assert int(dut.id_ex_instr_o.value) == first
        assert int(dut.id_ex_pc_o.value) == 0x1000
        await RisingEdge(dut.clk_i)
        await NextTimeStep()

    # Pop and push on the same edge replaces the entry without a bubble.
    dut.id_ex_ready_i.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    assert int(dut.id_ex_valid_o.value) == 1
    assert int(dut.id_ex_instr_o.value) == second
    assert int(dut.id_ex_pc_o.value) == 0x1004

    # When IF withdraws valid (as it does during redirect), consuming the current
    # EX instruction leaves the register empty without a dedicated flush input.
    dut.if_id_valid_i.value = 0
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    assert int(dut.id_ex_valid_o.value) == 0
