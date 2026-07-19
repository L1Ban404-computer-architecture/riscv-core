# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import NextTimeStep, RisingEdge, Timer


MASK32 = 0xFFFFFFFF

ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU = 0, 1, 2, 3, 4
ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR, ALU_AND, ALU_PASS_B = 5, 6, 7, 8, 9, 10
OP_A_RS1, OP_A_PC = 0, 1
OP_B_RS2, OP_B_IMM = 0, 1
BR_NONE, BR_JAL, BR_JALR, BR_BEQ, BR_BNE = 0, 1, 2, 3, 4
BR_BLT, BR_BGE, BR_BLTU, BR_BGEU = 5, 6, 7, 8
REDIR_NONE, REDIR_BRANCH, REDIR_JAL, REDIR_JALR = 0, 1, 2, 3
MEM_NONE, MEM_LOAD, MEM_STORE = 0, 1, 2
MEM_BYTE, MEM_HALF, MEM_WORD = 0, 1, 2
WB_NONE, WB_ALU, WB_MEM, WB_PC4 = 0, 1, 2, 3


def set_mem_wb(dut, *, valid=0, data_valid=0, rd=0, value=0):
    dut.mem_wb_valid_i.value = valid
    dut.mem_wb_data_valid_i.value = data_valid
    dut.mem_wb_rd_addr_i.value = rd
    dut.mem_wb_wdata_i.value = value & MASK32


def set_pending(dut, *, slot0=(0, 0), slot1=(0, 0)):
    dut.pending_0_valid_i.value, dut.pending_0_rd_addr_i.value = slot0
    dut.pending_1_valid_i.value, dut.pending_1_rd_addr_i.value = slot1


def drive_instruction(
    dut,
    *,
    tag=0x00000013,
    pc=0x80000000,
    rs1_addr=0,
    rs2_addr=0,
    rd=0,
    rs1=0,
    rs2=0,
    imm=0,
    alu=ALU_ADD,
    op_a=OP_A_RS1,
    op_b=OP_B_RS2,
    branch=BR_NONE,
    mem=MEM_NONE,
    size=MEM_WORD,
    sign_ext=0,
    wb=WB_NONE,
    rd_write=0,
    illegal=0,
    valid=1,
):
    dut.id_ex_valid_i.value = valid
    dut.id_ex_pc_i.value = pc & MASK32
    dut.id_ex_instr_i.value = tag & MASK32
    dut.id_ex_rs1_addr_i.value = rs1_addr
    dut.id_ex_rs2_addr_i.value = rs2_addr
    dut.id_ex_rd_addr_i.value = rd
    dut.id_ex_rs1_value_i.value = rs1 & MASK32
    dut.id_ex_rs2_value_i.value = rs2 & MASK32
    dut.id_ex_imm_i.value = imm & MASK32
    dut.id_ex_alu_op_i.value = alu
    dut.id_ex_op_a_sel_i.value = op_a
    dut.id_ex_op_b_sel_i.value = op_b
    dut.id_ex_branch_op_i.value = branch
    dut.id_ex_mem_cmd_i.value = mem
    dut.id_ex_mem_size_i.value = size
    dut.id_ex_mem_sign_ext_i.value = sign_ext
    dut.id_ex_wb_sel_i.value = wb
    dut.id_ex_rd_write_i.value = rd_write
    dut.id_ex_illegal_instr_i.value = illegal


async def reset_dut(dut):
    dut.rst_ni.value = 0
    dut.ex_mem_ready_i.value = 1
    set_mem_wb(dut)
    set_pending(dut)
    drive_instruction(dut, valid=0)
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    assert int(dut.ex_mem_valid_o.value) == 0


async def accept_current(dut):
    await Timer(1, unit="ns")
    assert int(dut.id_ex_ready_o.value) == 1
    redirect = (
        int(dut.redirect_valid_o.value),
        int(dut.redirect_target_pc_o.value),
        int(dut.redirect_reason_o.value),
    )
    await RisingEdge(dut.clk_i)
    dut.id_ex_valid_i.value = 0
    await NextTimeStep()
    assert int(dut.ex_mem_valid_o.value) == 1
    return redirect


async def drain_output(dut):
    dut.id_ex_valid_i.value = 0
    dut.ex_mem_ready_i.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    assert int(dut.ex_mem_valid_o.value) == 0


@cocotb.test()
async def alu_writeback_and_operand_selection(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    cases = [
        (ALU_ADD, 0x12345678, 0x11111111, 0x23456789),
        (ALU_SUB, 3, 5, 0xFFFFFFFE),
        (ALU_SLL, 1, 31, 0x80000000),
        (ALU_SLT, 0xFFFFFFFF, 1, 1),
        (ALU_SLTU, 0xFFFFFFFF, 1, 0),
        (ALU_XOR, 0xA5A55A5A, 0xFFFF0000, 0x5A5A5A5A),
        (ALU_SRL, 0x80000000, 4, 0x08000000),
        (ALU_SRA, 0x80000000, 4, 0xF8000000),
        (ALU_OR, 0x00FF00FF, 0xF0000F00, 0xF0FF0FFF),
        (ALU_AND, 0x55AA55AA, 0x0FF00FF0, 0x05A005A0),
        (ALU_PASS_B, 0xDEADBEEF, 0x13579BDF, 0x13579BDF),
    ]

    for index, (operation, operand_a, operand_b, expected) in enumerate(cases):
        drive_instruction(
            dut,
            tag=0x1000 + index,
            rs1=operand_a,
            rs2=operand_b,
            rd=3,
            alu=operation,
            wb=WB_ALU,
            rd_write=1,
        )
        redirect = await accept_current(dut)
        assert redirect[0] == 0
        assert int(dut.ex_mem_wb_valid_o.value) == 1
        assert int(dut.ex_mem_wb_data_valid_o.value) == 1
        assert int(dut.ex_mem_wb_rd_addr_o.value) == 3
        assert int(dut.ex_mem_wb_wdata_o.value) == expected
        await drain_output(dut)

    # PC/imm operand selection and the dedicated PC+4 writeback path.
    drive_instruction(
        dut,
        pc=0x2000,
        imm=0x1234,
        rd=4,
        alu=ALU_ADD,
        op_a=OP_A_PC,
        op_b=OP_B_IMM,
        wb=WB_ALU,
        rd_write=1,
    )
    await accept_current(dut)
    assert int(dut.ex_mem_wb_wdata_o.value) == 0x3234
    await drain_output(dut)

    drive_instruction(dut, pc=0xFFFFFFFC, rd=5, wb=WB_PC4, rd_write=1)
    await accept_current(dut)
    assert int(dut.ex_mem_wb_wdata_o.value) == 0
    await drain_output(dut)

    # WB_NONE, x0 and illegal instructions must not create a write request.
    for kwargs in (
        dict(rd=6, wb=WB_NONE, rd_write=1),
        dict(rd=0, wb=WB_ALU, rd_write=1),
        dict(rd=7, wb=WB_ALU, rd_write=1, illegal=1),
    ):
        drive_instruction(dut, rs1=1, rs2=2, **kwargs)
        await accept_current(dut)
        assert int(dut.ex_mem_wb_valid_o.value) == 0
        await drain_output(dut)


@cocotb.test()
async def branch_redirect_targets_and_debug(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    cases = [
        (BR_BEQ, 7, 7, True),
        (BR_BNE, 7, 8, True),
        (BR_BLT, 0xFFFFFFFF, 1, True),
        (BR_BGE, 1, 0xFFFFFFFF, True),
        (BR_BLTU, 1, 0xFFFFFFFF, True),
        (BR_BGEU, 0xFFFFFFFF, 1, True),
        (BR_BEQ, 7, 8, False),
    ]

    for index, (branch, rs1, rs2, taken) in enumerate(cases):
        pc = 0x4000 + index * 4
        drive_instruction(
            dut,
            tag=0x2000 + index,
            pc=pc,
            rs1=rs1,
            rs2=rs2,
            imm=0x20,
            alu=ALU_ADD,
            op_a=OP_A_PC,
            op_b=OP_B_IMM,
            branch=branch,
        )
        redirect = await accept_current(dut)
        assert redirect == (int(taken), pc + 0x20, REDIR_BRANCH)
        assert int(dut.ex_mem_debug_redirect_valid_o.value) == int(taken)
        assert int(dut.ex_mem_debug_redirect_target_o.value) == pc + 0x20
        await drain_output(dut)

    drive_instruction(
        dut,
        pc=0x8000,
        imm=0x100,
        rd=1,
        alu=ALU_ADD,
        op_a=OP_A_PC,
        op_b=OP_B_IMM,
        branch=BR_JAL,
        wb=WB_PC4,
        rd_write=1,
    )
    assert await accept_current(dut) == (1, 0x8100, REDIR_JAL)
    assert int(dut.ex_mem_wb_wdata_o.value) == 0x8004
    await drain_output(dut)

    drive_instruction(
        dut,
        rs1=0x9002,
        imm=3,
        alu=ALU_ADD,
        op_b=OP_B_IMM,
        branch=BR_JALR,
    )
    assert await accept_current(dut) == (1, 0x9004, REDIR_JALR)
    await drain_output(dut)

    # A taken control-flow instruction targeting its sequential successor must
    # not flush the frontend or report a redundant architectural redirect.
    drive_instruction(
        dut,
        pc=0xA000,
        rs1=0xA004,
        imm=0,
        alu=ALU_ADD,
        op_b=OP_B_IMM,
        branch=BR_JALR,
        wb=WB_PC4,
        rd=1,
        rd_write=1,
    )
    assert (await accept_current(dut))[0] == 0
    assert int(dut.ex_mem_debug_redirect_valid_o.value) == 0
    assert int(dut.ex_mem_wb_wdata_o.value) == 0xA004
    await drain_output(dut)

    drive_instruction(
        dut,
        pc=0xB000,
        imm=4,
        op_a=OP_A_PC,
        op_b=OP_B_IMM,
        branch=BR_JAL,
        illegal=1,
    )
    assert (await accept_current(dut))[0] == 0
    assert int(dut.ex_mem_debug_redirect_valid_o.value) == 0


@cocotb.test()
async def forwarding_priority_load_stall_and_false_dependencies(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    # Direct MEM/WB forwarding.
    set_mem_wb(dut, valid=1, data_valid=1, rd=1, value=0x12345678)
    drive_instruction(
        dut,
        rs1_addr=1,
        rs1=0,
        rs2=1,
        rd=2,
        wb=WB_ALU,
        rd_write=1,
    )
    await accept_current(dut)
    assert int(dut.ex_mem_wb_wdata_o.value) == 0x12345679
    await drain_output(dut)
    set_mem_wb(dut)

    # Any unresolved load in the MEM outstanding FIFO has priority over an
    # older completed MEM/WB value and must block the consumer.
    set_mem_wb(dut, valid=1, data_valid=1, rd=11, value=0x11111111)
    set_pending(dut, slot0=(1, 3), slot1=(1, 11))
    drive_instruction(
        dut,
        rs1_addr=11,
        rs1=0,
        rs2=1,
        rd=12,
        wb=WB_ALU,
        rd_write=1,
    )
    await Timer(1, unit="ns")
    assert int(dut.id_ex_ready_o.value) == 0

    set_pending(dut, slot0=(1, 3), slot1=(0, 0))
    await Timer(1, unit="ns")
    assert int(dut.id_ex_ready_o.value) == 1
    await RisingEdge(dut.clk_i)
    dut.id_ex_valid_i.value = 0
    await NextTimeStep()
    assert int(dut.ex_mem_wb_wdata_o.value) == 0x11111112
    await drain_output(dut)
    set_pending(dut)
    set_mem_wb(dut)

    # rs2 forwarding also supplies raw store data before it enters EX/MEM.
    set_mem_wb(dut, valid=1, data_valid=1, rd=2, value=0xA5A55A5A)
    drive_instruction(
        dut,
        rs1=0x2000,
        rs2_addr=2,
        rs2=0,
        imm=4,
        op_b=OP_B_IMM,
        mem=MEM_STORE,
        size=MEM_WORD,
    )
    await accept_current(dut)
    assert int(dut.ex_mem_mem_addr_o.value) == 0x2004
    assert int(dut.ex_mem_mem_wdata_o.value) == 0xA5A55A5A
    await drain_output(dut)
    set_mem_wb(dut)

    # Keep an ALU producer in EX/MEM, then replace it with a dependent consumer.
    drive_instruction(dut, rs1=0x11110000, rs2=0x2222, rd=5, wb=WB_ALU, rd_write=1)
    await accept_current(dut)
    assert int(dut.ex_mem_wb_wdata_o.value) == 0x11112222

    set_mem_wb(dut, valid=1, data_valid=1, rd=5, value=0xDEADBEEF)
    drive_instruction(
        dut,
        tag=0x3001,
        rs1_addr=5,
        rs1=0,
        rs2=1,
        rd=6,
        wb=WB_ALU,
        rd_write=1,
    )
    await accept_current(dut)
    assert int(dut.ex_mem_instr_o.value) == 0x3001
    assert int(dut.ex_mem_wb_wdata_o.value) == 0x11112223
    await drain_output(dut)
    set_mem_wb(dut)

    # A load in EX/MEM blocks a dependent consumer. Once it moves to MEM/WB,
    # data_valid continues to control the stall until the response is available.
    drive_instruction(
        dut,
        rs1=0x1000,
        imm=4,
        alu=ALU_ADD,
        op_b=OP_B_IMM,
        rd=7,
        mem=MEM_LOAD,
        wb=WB_MEM,
        rd_write=1,
    )
    await accept_current(dut)
    assert int(dut.ex_mem_wb_data_valid_o.value) == 0

    drive_instruction(
        dut,
        tag=0x3002,
        rs1_addr=7,
        rs1=0,
        rs2=1,
        rd=8,
        wb=WB_ALU,
        rd_write=1,
    )
    await Timer(1, unit="ns")
    assert int(dut.id_ex_ready_o.value) == 0
    await RisingEdge(dut.clk_i)  # The load leaves EX/MEM; consumer stays in ID/EX.
    set_mem_wb(dut, valid=1, data_valid=0, rd=7, value=0)
    await NextTimeStep()
    assert int(dut.ex_mem_valid_o.value) == 0
    assert int(dut.id_ex_ready_o.value) == 0

    set_mem_wb(dut, valid=1, data_valid=1, rd=7, value=0xCAFEBABE)
    await Timer(1, unit="ns")
    assert int(dut.id_ex_ready_o.value) == 1
    await RisingEdge(dut.clk_i)
    dut.id_ex_valid_i.value = 0
    await NextTimeStep()
    assert int(dut.ex_mem_wb_wdata_o.value) == 0xCAFEBABF
    await drain_output(dut)
    set_mem_wb(dut)

    # LUI/PASS_B does not read rs1, so a matching unavailable load must not
    # create a false dependency.
    drive_instruction(
        dut,
        rs1=0x2000,
        rd=9,
        mem=MEM_LOAD,
        wb=WB_MEM,
        rd_write=1,
    )
    await accept_current(dut)
    drive_instruction(
        dut,
        rs1_addr=9,
        rs1=0,
        imm=0xABCD0000,
        alu=ALU_PASS_B,
        op_b=OP_B_IMM,
        rd=10,
        wb=WB_ALU,
        rd_write=1,
    )
    await Timer(1, unit="ns")
    assert int(dut.id_ex_ready_o.value) == 1
    await RisingEdge(dut.clk_i)
    dut.id_ex_valid_i.value = 0
    await NextTimeStep()
    assert int(dut.ex_mem_wb_wdata_o.value) == 0xABCD0000


@cocotb.test()
async def mem_wb_forwarding_survives_ex_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    # Fill EX/MEM so the following ID/EX transaction cannot execute yet.
    dut.ex_mem_ready_i.value = 0
    drive_instruction(
        dut,
        tag=0x3100,
        rs1=0x10,
        rs2=0x20,
        rd=3,
        wb=WB_ALU,
        rd_write=1,
    )
    await accept_current(dut)

    # The held consumer has stale ID/EX operand values. Two older producers
    # retire on successive cycles while EX remains blocked.
    drive_instruction(
        dut,
        tag=0x3101,
        rs1_addr=1,
        rs2_addr=2,
        rs1=0x11111111,
        rs2=0x22222222,
        rd=4,
        wb=WB_ALU,
        rd_write=1,
    )
    set_mem_wb(dut, valid=1, data_valid=1, rd=1, value=0x12345678)
    await Timer(1, unit="ns")
    assert int(dut.id_ex_ready_o.value) == 0
    await RisingEdge(dut.clk_i)

    set_mem_wb(dut, valid=1, data_valid=1, rd=2, value=0x01020304)
    await NextTimeStep()
    assert int(dut.id_ex_ready_o.value) == 0
    await RisingEdge(dut.clk_i)

    # Both MEM/WB candidates have disappeared. Releasing EX/MEM must still use
    # their captured values instead of the stale values stored in ID/EX.
    set_mem_wb(dut)
    dut.ex_mem_ready_i.value = 1
    await NextTimeStep()
    assert int(dut.id_ex_ready_o.value) == 1
    await RisingEdge(dut.clk_i)
    dut.id_ex_valid_i.value = 0
    await NextTimeStep()

    assert int(dut.ex_mem_valid_o.value) == 1
    assert int(dut.ex_mem_instr_o.value) == 0x3101
    assert int(dut.ex_mem_wb_wdata_o.value) == 0x1336597C


@cocotb.test()
async def memory_request_address_and_raw_store_data(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    drive_instruction(
        dut,
        rs1=0x1000,
        rs2=0xA1B2C3D4,
        imm=3,
        alu=ALU_ADD,
        op_b=OP_B_IMM,
        mem=MEM_STORE,
        size=MEM_BYTE,
    )
    await accept_current(dut)
    assert int(dut.ex_mem_mem_valid_o.value) == 1
    assert int(dut.ex_mem_mem_write_o.value) == 1
    assert int(dut.ex_mem_mem_addr_o.value) == 0x1003
    assert int(dut.ex_mem_mem_wdata_o.value) == 0xA1B2C3D4
    assert int(dut.ex_mem_mem_size_o.value) == MEM_BYTE
    assert int(dut.ex_mem_wb_valid_o.value) == 0
    await drain_output(dut)

    drive_instruction(
        dut,
        rs1=0x2000,
        imm=2,
        alu=ALU_ADD,
        op_b=OP_B_IMM,
        rd=4,
        mem=MEM_LOAD,
        size=MEM_HALF,
        sign_ext=0,
        wb=WB_MEM,
        rd_write=1,
    )
    await accept_current(dut)
    assert int(dut.ex_mem_mem_valid_o.value) == 1
    assert int(dut.ex_mem_mem_write_o.value) == 0
    assert int(dut.ex_mem_mem_addr_o.value) == 0x2002
    assert int(dut.ex_mem_mem_size_o.value) == MEM_HALF
    assert int(dut.ex_mem_mem_sign_ext_o.value) == 0
    assert int(dut.ex_mem_wb_valid_o.value) == 1
    assert int(dut.ex_mem_wb_data_valid_o.value) == 0


@cocotb.test()
async def ex_mem_backpressure_stability_and_same_cycle_replacement(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    dut.ex_mem_ready_i.value = 0
    drive_instruction(
        dut,
        tag=0x4001,
        pc=0x1000,
        rs1=10,
        rs2=20,
        rd=3,
        wb=WB_ALU,
        rd_write=1,
    )
    await accept_current(dut)
    expected = (
        int(dut.ex_mem_instr_o.value),
        int(dut.ex_mem_pc_o.value),
        int(dut.ex_mem_wb_wdata_o.value),
    )

    drive_instruction(
        dut,
        tag=0x4002,
        pc=0x2000,
        imm=0x40,
        op_a=OP_A_PC,
        op_b=OP_B_IMM,
        branch=BR_JAL,
    )
    for _ in range(3):
        await Timer(1, unit="ns")
        assert int(dut.id_ex_ready_o.value) == 0
        assert int(dut.redirect_valid_o.value) == 0
        assert (
            int(dut.ex_mem_instr_o.value),
            int(dut.ex_mem_pc_o.value),
            int(dut.ex_mem_wb_wdata_o.value),
        ) == expected
        await RisingEdge(dut.clk_i)
        await NextTimeStep()

    # Pop the first result and push the JAL result on the same edge.
    dut.ex_mem_ready_i.value = 1
    await Timer(1, unit="ns")
    assert int(dut.id_ex_ready_o.value) == 1
    assert int(dut.redirect_valid_o.value) == 1
    assert int(dut.redirect_target_pc_o.value) == 0x2040
    await RisingEdge(dut.clk_i)
    dut.id_ex_valid_i.value = 0
    await NextTimeStep()
    assert int(dut.ex_mem_valid_o.value) == 1
    assert int(dut.ex_mem_instr_o.value) == 0x4002
    assert int(dut.ex_mem_debug_redirect_valid_o.value) == 1
    assert int(dut.ex_mem_debug_redirect_target_o.value) == 0x2040
