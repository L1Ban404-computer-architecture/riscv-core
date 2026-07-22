# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


MASK32 = 0xFFFFFFFF


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    drive_payload(dut, valid=0)
    dut.rst_ni.value = 0
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await RisingEdge(dut.clk_i)


def drive_payload(
    dut,
    *,
    valid=1,
    wb_valid=1,
    wb_data_valid=1,
    wb_rd=7,
    wb_data=0x12345678,
    pc=0x80000000,
    instr=0x00C585B3,
):
    dut.mem_wb_valid_i.value = valid
    dut.wb_valid_i.value = wb_valid
    dut.wb_data_valid_i.value = wb_data_valid
    dut.wb_rd_addr_i.value = wb_rd
    dut.wb_wdata_i.value = wb_data & MASK32

    dut.fetch_pc_i.value = pc & MASK32
    dut.fetch_instr_i.value = instr & MASK32
    dut.redirect_valid_i.value = 1
    dut.redirect_target_pc_i.value = 0x80000100
    dut.mem_req_valid_i.value = 1
    dut.mem_req_write_i.value = 0
    dut.mem_req_size_i.value = 2
    dut.mem_req_addr_i.value = 0x1003
    dut.mem_req_wdata_i.value = 0xA5A55A5A


def assert_zeroed_outputs(dut):
    assert int(dut.wb_valid_o.value) == 0
    assert int(dut.wb_data_valid_o.value) == 0
    assert int(dut.wb_rd_addr_o.value) == 0
    assert int(dut.wb_wdata_o.value) == 0
    assert int(dut.retire_valid_o.value) == 0
    assert int(dut.retire_pc_o.value) == 0
    assert int(dut.retire_instr_o.value) == 0
    assert int(dut.retire_gpr_we_o.value) == 0
    assert int(dut.state_cycle_count_o.value) == 0
    assert int(dut.state_instret_count_o.value) == 0
    assert int(dut.state_trap_o.value) == 0


@cocotb.test()
async def valid_transaction_writes_back_and_flattens_debug(dut):
    await reset_dut(dut)
    drive_payload(dut)
    await RisingEdge(dut.clk_i)
    await ReadOnly()

    assert int(dut.mem_wb_ready_o.value) == 1
    assert int(dut.wb_valid_o.value) == 1
    assert int(dut.wb_data_valid_o.value) == 1
    assert int(dut.wb_rd_addr_o.value) == 7
    assert int(dut.wb_wdata_o.value) == 0x12345678

    assert int(dut.retire_valid_o.value) == 1
    assert int(dut.retire_pc_o.value) == 0x80000000
    assert int(dut.retire_instr_o.value) == 0x00C585B3
    assert int(dut.retire_redirect_valid_o.value) == 1
    assert int(dut.retire_redirect_target_pc_o.value) == 0x80000100
    assert int(dut.retire_mem_req_valid_o.value) == 1
    assert int(dut.retire_mem_req_write_o.value) == 0
    assert int(dut.retire_mem_req_size_o.value) == 2
    assert int(dut.retire_mem_req_addr_o.value) == 0x1003
    assert int(dut.retire_mem_req_wdata_o.value) == 0xA5A55A5A
    assert int(dut.retire_gpr_we_o.value) == 1
    assert int(dut.retire_gpr_waddr_o.value) == 7
    assert int(dut.retire_gpr_wdata_o.value) == 0x12345678
    assert int(dut.state_cycle_count_o.value) == 2
    assert int(dut.state_instret_count_o.value) == 1


@cocotb.test()
async def instruction_without_register_write_still_retires(dut):
    await reset_dut(dut)
    drive_payload(
        dut,
        wb_valid=0,
        wb_data_valid=0,
        wb_rd=0,
        wb_data=0,
        pc=0x80000020,
        instr=0x00B52023,
    )
    await RisingEdge(dut.clk_i)
    await ReadOnly()

    assert int(dut.mem_wb_ready_o.value) == 1
    assert int(dut.retire_valid_o.value) == 1
    assert int(dut.retire_pc_o.value) == 0x80000020
    assert int(dut.retire_instr_o.value) == 0x00B52023
    assert int(dut.wb_valid_o.value) == 0
    assert int(dut.retire_gpr_we_o.value) == 0


@cocotb.test()
async def bubble_masks_stale_payload(dut):
    await reset_dut(dut)
    drive_payload(dut, valid=0)
    await RisingEdge(dut.clk_i)
    await ReadOnly()

    assert int(dut.mem_wb_ready_o.value) == 1
    assert_zeroed_outputs(dut)

    await FallingEdge(dut.clk_i)
    drive_payload(dut, valid=1, wb_rd=0, wb_data=0xFFFFFFFF)
    await RisingEdge(dut.clk_i)
    await ReadOnly()
    # WB preserves the request semantics; the register file owns x0 filtering.
    assert int(dut.wb_valid_o.value) == 1
    assert int(dut.wb_rd_addr_o.value) == 0
    assert int(dut.retire_valid_o.value) == 1

    await FallingEdge(dut.clk_i)
    dut.mem_wb_valid_i.value = 0
    await RisingEdge(dut.clk_i)
    await ReadOnly()
    assert int(dut.wb_valid_o.value) == 0
    assert int(dut.retire_valid_o.value) == 0
    assert int(dut.retire_pc_o.value) == 0x80000000
    assert int(dut.retire_instr_o.value) == 0x00C585B3
    assert int(dut.retire_gpr_waddr_o.value) == 0
    assert int(dut.retire_gpr_wdata_o.value) == 0xFFFFFFFF
    assert int(dut.state_cycle_count_o.value) == 3
    assert int(dut.state_instret_count_o.value) == 1


@cocotb.test()
async def consecutive_retirements_keep_valid_high_and_replace_snapshots(dut):
    await reset_dut(dut)
    drive_payload(dut, pc=0x80000000, instr=0x00100093, wb_rd=1, wb_data=1)
    await RisingEdge(dut.clk_i)
    await ReadOnly()
    assert int(dut.retire_valid_o.value) == 1
    assert int(dut.retire_pc_o.value) == 0x80000000
    assert int(dut.state_cycle_count_o.value) == 2
    assert int(dut.state_instret_count_o.value) == 1

    await FallingEdge(dut.clk_i)
    drive_payload(dut, pc=0x80000004, instr=0x00200113, wb_rd=2, wb_data=2)
    await RisingEdge(dut.clk_i)
    await ReadOnly()
    assert int(dut.retire_valid_o.value) == 1
    assert int(dut.retire_pc_o.value) == 0x80000004
    assert int(dut.retire_instr_o.value) == 0x00200113
    assert int(dut.retire_gpr_waddr_o.value) == 2
    assert int(dut.retire_gpr_wdata_o.value) == 2
    assert int(dut.state_cycle_count_o.value) == 3
    assert int(dut.state_instret_count_o.value) == 2
