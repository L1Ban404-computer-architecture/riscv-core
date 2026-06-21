# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import NextTimeStep, ReadOnly, RisingEdge


async def reset_dut(dut):
    dut.rst_ni.value = 0
    dut.flush_i.value = 0
    dut.valid_i.value = 0
    dut.ready_i.value = 0
    dut.data_i.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()


def check_usage(dut, expected):
    assert int(dut.usage_o.value) == expected
    assert int(dut.peek_usage_o.value) == expected
    assert int(dut.peek_valid_count_o.value) == expected


@cocotb.test()
async def empty_fall_through_and_flush(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    fall_through = int(dut.config_fall_through_o.value)

    check_usage(dut, 0)
    dut.valid_i.value = 1
    dut.ready_i.value = 1
    dut.data_i.value = 0x12345678
    await ReadOnly()
    assert int(dut.ready_o.value) == 1
    assert int(dut.valid_o.value) == fall_through
    if fall_through:
        assert int(dut.data_o.value) == 0x12345678

    await RisingEdge(dut.clk_i)
    dut.valid_i.value = 0
    await NextTimeStep()

    if fall_through:
        check_usage(dut, 0)
    else:
        check_usage(dut, 1)
        assert int(dut.valid_o.value) == 1
        assert int(dut.data_o.value) == 0x12345678
        await RisingEdge(dut.clk_i)
        await NextTimeStep()
        check_usage(dut, 0)

    dut.ready_i.value = 0
    dut.valid_i.value = 1
    dut.data_i.value = 0xA5A55A5A
    await RisingEdge(dut.clk_i)
    dut.valid_i.value = 0
    await NextTimeStep()
    check_usage(dut, 1)

    dut.flush_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.flush_i.value = 0
    await NextTimeStep()
    check_usage(dut, 0)
    assert int(dut.valid_o.value) == 0


@cocotb.test()
async def full_same_cycle_replacement_and_order(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    depth = int(dut.config_depth_o.value)
    same_cycle_rw = int(dut.config_same_cycle_rw_o.value)

    dut.ready_i.value = 0
    for value in range(depth):
        dut.valid_i.value = 1
        dut.data_i.value = 0x100 + value
        await ReadOnly()
        assert int(dut.ready_o.value) == 1
        await RisingEdge(dut.clk_i)
        await NextTimeStep()

    dut.valid_i.value = 0
    check_usage(dut, depth)
    assert int(dut.data_o.value) == 0x100

    replacement = 0x200
    dut.ready_i.value = 1
    dut.valid_i.value = 1
    dut.data_i.value = replacement
    await ReadOnly()
    assert int(dut.ready_o.value) == same_cycle_rw
    assert int(dut.valid_o.value) == 1
    assert int(dut.data_o.value) == 0x100

    await RisingEdge(dut.clk_i)
    dut.valid_i.value = 0
    await NextTimeStep()

    expected = [0x100 + value for value in range(1, depth)]
    if same_cycle_rw:
        expected.append(replacement)
        check_usage(dut, depth)
    else:
        check_usage(dut, depth - 1)

    for value in expected:
        await ReadOnly()
        assert int(dut.valid_o.value) == 1
        assert int(dut.data_o.value) == value
        await RisingEdge(dut.clk_i)
        await NextTimeStep()

    check_usage(dut, 0)
    assert int(dut.valid_o.value) == 0

    # 再次写满并排空，覆盖非 2 次幂深度的指针回绕。
    dut.ready_i.value = 0
    for value in range(depth):
        dut.valid_i.value = 1
        dut.data_i.value = 0x300 + value
        await RisingEdge(dut.clk_i)
        await NextTimeStep()
    dut.valid_i.value = 0
    dut.ready_i.value = 1
    for value in range(depth):
        await ReadOnly()
        assert int(dut.data_o.value) == 0x300 + value
        await RisingEdge(dut.clk_i)
        await NextTimeStep()
    check_usage(dut, 0)
