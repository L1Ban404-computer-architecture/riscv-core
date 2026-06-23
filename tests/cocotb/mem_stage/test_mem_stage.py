# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import NextTimeStep, RisingEdge, Timer


MASK32 = 0xFFFFFFFF
MEM_BYTE, MEM_HALF, MEM_WORD = 0, 1, 2


def drive_transaction(
    dut,
    *,
    valid=1,
    pc=0x80000000,
    instr=0x13,
    mem_valid=0,
    write=0,
    size=MEM_WORD,
    sign_ext=0,
    addr=0,
    store_data=0,
    wb_valid=0,
    wb_data_valid=0,
    rd=0,
    wb_data=0,
):
    dut.ex_mem_valid_i.value = valid
    dut.ex_mem_pc_i.value = pc & MASK32
    dut.ex_mem_instr_i.value = instr & MASK32
    dut.ex_mem_mem_valid_i.value = mem_valid
    dut.ex_mem_mem_write_i.value = write
    dut.ex_mem_mem_size_i.value = size
    dut.ex_mem_mem_sign_ext_i.value = sign_ext
    dut.ex_mem_mem_addr_i.value = addr & MASK32
    dut.ex_mem_mem_wdata_i.value = store_data & MASK32
    dut.ex_mem_wb_valid_i.value = wb_valid
    dut.ex_mem_wb_data_valid_i.value = wb_data_valid
    dut.ex_mem_wb_rd_addr_i.value = rd
    dut.ex_mem_wb_wdata_i.value = wb_data & MASK32


def drive_response(dut, *, valid=0, data=0, error=0):
    dut.dmem_rsp_valid_i.value = valid
    dut.dmem_rsp_rdata_i.value = data & MASK32
    dut.dmem_rsp_error_i.value = error


def pending_entries(dut):
    entries = []
    if int(dut.pending_0_valid_o.value):
        entries.append(int(dut.pending_0_rd_addr_o.value))
    if int(dut.pending_1_valid_o.value):
        entries.append(int(dut.pending_1_rd_addr_o.value))
    return sorted(entries)


async def reset_dut(dut):
    dut.rst_ni.value = 0
    dut.dmem_req_ready_i.value = 0
    dut.mem_wb_ready_i.value = 1
    drive_response(dut)
    drive_transaction(dut, valid=0)
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    assert int(dut.mem_wb_valid_o.value) == 0
    assert pending_entries(dut) == []


async def issue_memory(dut, **kwargs):
    drive_transaction(dut, mem_valid=1, **kwargs)
    await Timer(1, unit="ns")
    assert int(dut.dmem_req_valid_o.value) == 1
    assert int(dut.ex_mem_ready_o.value) == 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()


async def return_response(dut, data=0):
    drive_response(dut, valid=1, data=data)
    await Timer(1, unit="ns")
    assert int(dut.dmem_rsp_ready_o.value) == 1
    await RisingEdge(dut.clk_i)
    drive_response(dut)
    await NextTimeStep()


@cocotb.test()
async def non_memory_bypass_and_mem_wb_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    dut.mem_wb_ready_i.value = 0
    drive_transaction(
        dut,
        pc=0x1000,
        instr=0x1111,
        wb_valid=1,
        wb_data_valid=1,
        rd=3,
        wb_data=0x12345678,
    )
    await Timer(1, unit="ns")
    assert int(dut.ex_mem_ready_o.value) == 1
    assert int(dut.dmem_req_valid_o.value) == 0
    await RisingEdge(dut.clk_i)
    drive_transaction(dut, valid=0)
    await NextTimeStep()

    assert int(dut.mem_wb_valid_o.value) == 1
    assert int(dut.mem_wb_req_valid_o.value) == 1
    assert int(dut.mem_wb_req_rd_addr_o.value) == 3
    assert int(dut.mem_wb_req_wdata_o.value) == 0x12345678

    snapshot = (
        int(dut.mem_wb_pc_o.value),
        int(dut.mem_wb_instr_o.value),
        int(dut.mem_wb_req_wdata_o.value),
    )
    for _ in range(2):
        await RisingEdge(dut.clk_i)
        await NextTimeStep()
        assert (
            int(dut.mem_wb_pc_o.value),
            int(dut.mem_wb_instr_o.value),
            int(dut.mem_wb_req_wdata_o.value),
        ) == snapshot


@cocotb.test()
async def store_alignment_and_load_extraction(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    dut.dmem_req_ready_i.value = 1

    await issue_memory(
        dut,
        pc=0x2000,
        instr=0x2222,
        write=1,
        size=MEM_BYTE,
        addr=0x1003,
        store_data=0xA1B2C3D4,
    )
    assert int(dut.dmem_req_addr_o.value) == 0x1000
    assert int(dut.dmem_req_wdata_o.value) == 0xD4000000
    assert int(dut.dmem_req_wstrb_o.value) == 0b1000
    drive_transaction(dut, valid=0)
    await return_response(dut, 0)
    assert int(dut.mem_wb_mem_valid_o.value) == 1
    assert int(dut.mem_wb_mem_write_o.value) == 1
    assert int(dut.mem_wb_rsp_valid_o.value) == 1
    await RisingEdge(dut.clk_i)

    await issue_memory(
        dut,
        pc=0x2004,
        instr=0x2223,
        write=0,
        size=MEM_BYTE,
        sign_ext=1,
        addr=0x3001,
        wb_valid=1,
        rd=7,
    )
    assert int(dut.dmem_req_addr_o.value) == 0x3000
    assert int(dut.dmem_req_wdata_o.value) == 0
    assert int(dut.dmem_req_wstrb_o.value) == 0
    drive_transaction(dut, valid=0)
    await return_response(dut, 0x00008000)
    assert int(dut.mem_wb_req_valid_o.value) == 1
    assert int(dut.mem_wb_req_data_valid_o.value) == 1
    assert int(dut.mem_wb_req_rd_addr_o.value) == 7
    assert int(dut.mem_wb_req_wdata_o.value) == 0xFFFFFF80
    assert int(dut.mem_wb_rsp_rdata_o.value) == 0x00008000

    # LBU must zero-extend the selected byte instead of inheriting LB's sign extension.
    await RisingEdge(dut.clk_i)
    await issue_memory(
        dut,
        pc=0x2008,
        instr=0x2224,
        write=0,
        size=MEM_BYTE,
        sign_ext=0,
        addr=0x3001,
        wb_valid=1,
        rd=8,
    )
    drive_transaction(dut, valid=0)
    await return_response(dut, 0x00008000)
    assert int(dut.mem_wb_req_valid_o.value) == 1
    assert int(dut.mem_wb_req_data_valid_o.value) == 1
    assert int(dut.mem_wb_req_rd_addr_o.value) == 8
    assert int(dut.mem_wb_req_wdata_o.value) == 0x00000080


@cocotb.test()
async def multiple_outstanding_preserves_retirement_order(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    dut.dmem_req_ready_i.value = 1

    await issue_memory(dut, pc=0x4000, instr=0x4001, addr=0x1000,
                       wb_valid=1, rd=5)
    assert pending_entries(dut) == [5]
    await issue_memory(dut, pc=0x4004, instr=0x4002, addr=0x1004,
                       wb_valid=1, rd=6)
    assert pending_entries(dut) == [5, 6]

    # A younger ALU result cannot bypass either outstanding load.
    drive_transaction(
        dut,
        pc=0x4008,
        instr=0x4003,
        wb_valid=1,
        wb_data_valid=1,
        rd=8,
        wb_data=0x88888888,
    )
    await Timer(1, unit="ns")
    assert int(dut.ex_mem_ready_o.value) == 0

    dut.mem_wb_ready_i.value = 0
    await return_response(dut, 0x55555555)
    assert int(dut.mem_wb_instr_o.value) == 0x4001
    assert int(dut.mem_wb_req_wdata_o.value) == 0x55555555
    assert pending_entries(dut) == [6]
    assert int(dut.ex_mem_ready_o.value) == 0

    # MEM/WB backpressure also backpressures the CoreBus response.
    drive_response(dut, valid=1, data=0x66666666)
    await Timer(1, unit="ns")
    assert int(dut.dmem_rsp_ready_o.value) == 0

    dut.mem_wb_ready_i.value = 1
    await Timer(1, unit="ns")
    assert int(dut.dmem_rsp_ready_o.value) == 1
    await RisingEdge(dut.clk_i)
    drive_response(dut)
    await NextTimeStep()
    assert int(dut.mem_wb_instr_o.value) == 0x4002
    assert int(dut.mem_wb_req_wdata_o.value) == 0x66666666
    assert pending_entries(dut) == []

    # Once all older memory operations have reached MEM/WB, the ALU result can
    # replace the second load in the output register on the next edge.
    await Timer(1, unit="ns")
    assert int(dut.ex_mem_ready_o.value) == 1
    await RisingEdge(dut.clk_i)
    drive_transaction(dut, valid=0)
    await NextTimeStep()
    assert int(dut.mem_wb_instr_o.value) == 0x4003
    assert int(dut.mem_wb_req_wdata_o.value) == 0x88888888


@cocotb.test()
async def full_fifo_pop_push_and_zero_latency_response(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    dut.dmem_req_ready_i.value = 1

    await issue_memory(dut, instr=0x5001, addr=0x1000, wb_valid=1, rd=1)
    await issue_memory(dut, instr=0x5002, addr=0x1004, wb_valid=1, rd=2)
    assert pending_entries(dut) == [1, 2]

    # A response frees the full FIFO in the same cycle that a third request
    # occupies the released slot.
    drive_transaction(
        dut,
        instr=0x5003,
        mem_valid=1,
        addr=0x1008,
        wb_valid=1,
        rd=3,
    )
    drive_response(dut, valid=1, data=0x11111111)
    await Timer(1, unit="ns")
    assert int(dut.dmem_rsp_ready_o.value) == 1
    assert int(dut.dmem_req_valid_o.value) == 1
    assert int(dut.ex_mem_ready_o.value) == 1
    await RisingEdge(dut.clk_i)
    drive_transaction(dut, valid=0)
    drive_response(dut)
    await NextTimeStep()
    assert pending_entries(dut) == [2, 3]
    assert int(dut.mem_wb_instr_o.value) == 0x5001

    # Drain both entries before checking empty-FIFO fall-through behavior.
    await return_response(dut, 0x22222222)
    await return_response(dut, 0x33333333)
    assert pending_entries(dut) == []

    drive_transaction(
        dut,
        instr=0x5004,
        mem_valid=1,
        addr=0x2000,
        wb_valid=1,
        rd=4,
    )
    drive_response(dut, valid=1, data=0x44444444)
    await Timer(1, unit="ns")
    assert int(dut.dmem_req_valid_o.value) == 1
    assert int(dut.dmem_rsp_ready_o.value) == 1
    await RisingEdge(dut.clk_i)
    drive_transaction(dut, valid=0)
    drive_response(dut)
    await NextTimeStep()
    assert pending_entries(dut) == []
    assert int(dut.mem_wb_instr_o.value) == 0x5004
    assert int(dut.mem_wb_req_wdata_o.value) == 0x44444444
