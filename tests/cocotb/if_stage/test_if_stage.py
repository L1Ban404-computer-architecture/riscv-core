# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

from collections import deque
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, ReadWrite, NextTimeStep


OKAY = 0
SLVERR = 2
WRITE_MONITOR_STARTED = False


def env_int(name: str, default: int) -> int:
    try:
        return int(cocotb.plusargs.get(name, default))
    except (TypeError, ValueError):
        return default


def instr_for_pc(pc: int) -> int:
    return (0x13000000 ^ ((pc >> 2) * 0x1021)) & 0xFFFFFFFF


async def write_channel_idle_monitor(dut):
    while True:
        await ReadOnly()
        if int(dut.rst_ni.value):
            assert int(dut.imem_aw_valid_o.value) == 0
            assert int(dut.imem_w_valid_o.value) == 0
            assert int(dut.imem_b_ready_o.value) == 0
            assert int(dut.imem_aw_addr_o.value) == 0
            assert int(dut.imem_aw_prot_o.value) == 0b100
            assert int(dut.imem_w_data_o.value) == 0
            assert int(dut.imem_w_strb_o.value) == 0

        await RisingEdge(dut.clk_i)
        await NextTimeStep()


async def reset_dut(dut, boot_pc=0x8000_0000):
    global WRITE_MONITOR_STARTED

    dut.boot_pc_i.value = boot_pc
    dut.redirect_valid_i.value = 0
    dut.redirect_target_pc_i.value = 0
    dut.imem_ar_ready_i.value = 0
    dut.imem_r_valid_i.value = 0
    dut.imem_r_data_i.value = 0
    dut.imem_r_resp_i.value = OKAY
    dut.if_id_ready_i.value = 1
    dut.rst_ni.value = 0

    if not WRITE_MONITOR_STARTED:
        cocotb.start_soon(write_channel_idle_monitor(dut))
        WRITE_MONITOR_STARTED = True

    for _ in range(3):
        await RisingEdge(dut.clk_i)

    dut.rst_ni.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())


async def wait_cycles(dut, count):
    for _ in range(count):
        await RisingEdge(dut.clk_i)
        await NextTimeStep()


async def accept_ar(dut, count, ready_pattern=None, check_stable=True):
    accepted = []
    wait_addr = None
    wait_prot = None

    for cycle in range(1000):
        ready = 1 if ready_pattern is None else int(bool(ready_pattern(cycle)))
        dut.imem_ar_ready_i.value = ready

        await ReadOnly()
        valid = int(dut.imem_ar_valid_o.value)
        addr = int(dut.imem_ar_addr_o.value)
        prot = int(dut.imem_ar_prot_o.value)

        if check_stable and wait_addr is not None:
            assert valid == 1, "AR valid dropped before handshake"
            assert addr == wait_addr, "AR addr changed before handshake"
            assert prot == wait_prot, "AR prot changed before handshake"

        if valid and not ready:
            if wait_addr is None:
                wait_addr = addr
                wait_prot = prot

        if valid and ready:
            accepted.append(addr)
            assert prot == 0b100
            wait_addr = None
            wait_prot = None
            await RisingEdge(dut.clk_i)
            await NextTimeStep()
            if len(accepted) == count:
                dut.imem_ar_ready_i.value = 0
                return accepted
            continue

        await RisingEdge(dut.clk_i)
        await NextTimeStep()

    raise AssertionError(f"Timed out waiting for {count} AR handshakes")


async def send_r_for_pcs(dut, pcs, zero_latency=False):
    for pc in pcs:
        dut.imem_r_data_i.value = instr_for_pc(pc)
        dut.imem_r_resp_i.value = OKAY
        dut.imem_r_valid_i.value = 1

        for _ in range(1000):
            await ReadOnly()
            ready = int(dut.imem_r_ready_o.value)
            await RisingEdge(dut.clk_i)
            await NextTimeStep()
            if ready:
                break
        else:
            raise AssertionError("Timed out waiting for R ready")

    dut.imem_r_valid_i.value = 0
    dut.imem_r_data_i.value = 0


def check_fetch_outputs(dut, expected_fetches, context=""):
    if int(dut.if_id_valid_o.value) and int(dut.if_id_ready_i.value):
        assert expected_fetches, "IF/ID produced an unexpected fetch"
        expected_pc = expected_fetches.popleft()
        got_pc = int(dut.if_id_pc_o.value)
        got_instr = int(dut.if_id_instr_o.value)
        assert got_pc == expected_pc, (
            f"{context}: expected pc 0x{expected_pc:08x}, got 0x{got_pc:08x}"
        )
        assert got_instr == instr_for_pc(expected_pc)
        assert int(dut.if_id_debug_pc_o.value) == expected_pc
        assert int(dut.if_id_debug_instr_o.value) == instr_for_pc(expected_pc)


async def send_and_collect_fetches(dut, pcs, fetch_count=None):
    expected_count = len(pcs) if fetch_count is None else fetch_count
    remaining_responses = deque(pcs)
    current_pc = None
    got = []

    dut.if_id_ready_i.value = 1

    for _ in range(1000):
        await ReadWrite()

        if current_pc is None and remaining_responses:
            current_pc = remaining_responses.popleft()

        if current_pc is None:
            dut.imem_r_valid_i.value = 0
            dut.imem_r_data_i.value = 0
        else:
            dut.imem_r_valid_i.value = 1
            dut.imem_r_data_i.value = instr_for_pc(current_pc)
            dut.imem_r_resp_i.value = OKAY

        await ReadOnly()
        r_fire = int(dut.imem_r_valid_i.value) and int(dut.imem_r_ready_o.value)
        if_id_fire = int(dut.if_id_valid_o.value) and int(dut.if_id_ready_i.value)

        if if_id_fire:
            pc = int(dut.if_id_pc_o.value)
            instr = int(dut.if_id_instr_o.value)
            debug_pc = int(dut.if_id_debug_pc_o.value)
            debug_instr = int(dut.if_id_debug_instr_o.value)
            assert debug_pc == pc
            assert debug_instr == instr
            got.append((pc, instr))

        await RisingEdge(dut.clk_i)
        await NextTimeStep()

        if r_fire:
            current_pc = None
        if len(got) == expected_count:
            dut.imem_r_valid_i.value = 0
            dut.imem_r_data_i.value = 0
            return got

    raise AssertionError(f"Timed out waiting for {expected_count} IF/ID handshakes")


async def collect_fetches(dut, count):
    got = []
    dut.if_id_ready_i.value = 1

    for _ in range(1000):
        await ReadOnly()
        if int(dut.if_id_valid_o.value) and int(dut.if_id_ready_i.value):
            pc = int(dut.if_id_pc_o.value)
            instr = int(dut.if_id_instr_o.value)
            debug_pc = int(dut.if_id_debug_pc_o.value)
            debug_instr = int(dut.if_id_debug_instr_o.value)
            assert debug_pc == pc
            assert debug_instr == instr
            got.append((pc, instr))
            await RisingEdge(dut.clk_i)
            await NextTimeStep()
            if len(got) == count:
                return got
            continue

        await RisingEdge(dut.clk_i)
        await NextTimeStep()

    raise AssertionError(f"Timed out waiting for {count} IF/ID handshakes")


@cocotb.test()
async def reset_boot_and_basic_fetch(dut):
    await start_clock(dut)
    boot_pc = 0x8000_0000
    await reset_dut(dut, boot_pc)

    pcs = await accept_ar(dut, 4)
    assert pcs == [boot_pc + 4 * i for i in range(4)]

    got = await send_and_collect_fetches(dut, pcs)
    assert got == [(pc, instr_for_pc(pc)) for pc in pcs]


@cocotb.test()
async def ar_valid_and_payload_hold_under_backpressure(dut):
    await start_clock(dut)
    boot_pc = 0x8000_1000
    await reset_dut(dut, boot_pc)

    pcs = await accept_ar(
        dut,
        3,
        ready_pattern=lambda cycle: cycle in (4, 8, 9),
        check_stable=True,
    )
    assert pcs[0] == boot_pc
    assert pcs[1] == boot_pc + 4
    assert pcs[2] == boot_pc + 8


@cocotb.test()
async def zero_latency_memory_response(dut):
    await start_clock(dut)
    boot_pc = 0x8000_2000
    await reset_dut(dut, boot_pc)

    pending = deque()
    got = []
    dut.if_id_ready_i.value = 1
    dut.imem_ar_ready_i.value = 1

    for _ in range(40):
        await ReadWrite()

        ar_valid = int(dut.imem_ar_valid_o.value)
        ar_ready = int(dut.imem_ar_ready_i.value)
        if ar_valid and ar_ready:
            pending.append(int(dut.imem_ar_addr_o.value))

        if pending:
            pc = pending[0]
            dut.imem_r_data_i.value = instr_for_pc(pc)
            dut.imem_r_valid_i.value = 1
        else:
            dut.imem_r_valid_i.value = 0

        await ReadOnly()
        r_fire = int(dut.imem_r_valid_i.value) and int(dut.imem_r_ready_o.value)
        if_id_fire = int(dut.if_id_valid_o.value) and int(dut.if_id_ready_i.value)
        if if_id_fire:
            got.append((int(dut.if_id_pc_o.value), int(dut.if_id_instr_o.value)))

        await RisingEdge(dut.clk_i)
        await NextTimeStep()

        if r_fire:
            pending.popleft()
        if len(got) == 4:
            break

    expected_pcs = [boot_pc + 4 * i for i in range(4)]
    assert got == [(pc, instr_for_pc(pc)) for pc in expected_pcs]


@cocotb.test()
async def if_id_backpressure_preserves_fetch_order(dut):
    await start_clock(dut)
    boot_pc = 0x8000_3000
    await reset_dut(dut, boot_pc)

    pcs = await accept_ar(dut, 4)
    dut.if_id_ready_i.value = 0
    await send_r_for_pcs(dut, pcs[:2])

    dut.imem_r_data_i.value = instr_for_pc(pcs[2])
    dut.imem_r_resp_i.value = OKAY
    dut.imem_r_valid_i.value = 1
    await wait_cycles(dut, 5)
    await ReadOnly()
    assert int(dut.imem_r_ready_o.value) == 0
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    dut.imem_r_valid_i.value = 0

    got = await send_and_collect_fetches(dut, pcs[2:], fetch_count=4)
    assert got == [(pc, instr_for_pc(pc)) for pc in pcs]


@cocotb.test()
async def redirect_discards_old_outstanding_responses(dut):
    await start_clock(dut)
    boot_pc = 0x8000_4000
    target_pc = 0x8000_8000
    await reset_dut(dut, boot_pc)

    old_pcs = await accept_ar(dut, 3)

    dut.redirect_target_pc_i.value = target_pc
    dut.redirect_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    dut.redirect_valid_i.value = 0

    # fall-through AR hold 下，redirect 同周期的组合新请求可以被取消；
    # 但如果已有旧请求实际完成 AR 握手，它的响应应由 epoch 机制丢弃。
    first_after_redirect = (await accept_ar(dut, 1))[0]
    stale_pcs = []
    new_pcs = []
    if first_after_redirect == target_pc:
        new_pcs.append(first_after_redirect)
    else:
        stale_pcs.append(first_after_redirect)
        assert first_after_redirect == old_pcs[-1] + 4

    await send_r_for_pcs(dut, old_pcs + stale_pcs)
    await wait_cycles(dut, 3)
    assert int(dut.if_id_valid_o.value) == 0

    while len(new_pcs) < 2:
        new_pcs.extend(await accept_ar(dut, 1))
    assert new_pcs[0] == target_pc
    assert new_pcs[1] == target_pc + 4

    got = await send_and_collect_fetches(dut, new_pcs)
    assert got == [(pc, instr_for_pc(pc)) for pc in new_pcs]


@cocotb.test()
async def redirect_during_ar_wait_preserves_axi_request(dut):
    await start_clock(dut)
    boot_pc = 0x8000_5000
    target_pc = 0x8000_A000
    await reset_dut(dut, boot_pc)

    dut.imem_ar_ready_i.value = 0

    # 先等待 AR valid 在 ar_ready=0 的时钟沿被采样到。AXI 的 valid
    # 保持约束从这个采样点之后开始，而不是从同周期组合短暂可见开始。
    while True:
        await ReadOnly()
        ar_wait_sampled = int(dut.imem_ar_valid_o.value) and not int(dut.imem_ar_ready_i.value)
        held_addr = int(dut.imem_ar_addr_o.value)
        held_prot = int(dut.imem_ar_prot_o.value)
        await RisingEdge(dut.clk_i)
        await NextTimeStep()
        if ar_wait_sampled:
            break

    assert held_addr == boot_pc

    dut.redirect_target_pc_i.value = target_pc
    dut.redirect_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()

    assert int(dut.imem_ar_valid_o.value) == 1
    assert int(dut.imem_ar_addr_o.value) == held_addr
    assert int(dut.imem_ar_prot_o.value) == held_prot

    dut.redirect_valid_i.value = 0
    dut.imem_ar_ready_i.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    dut.imem_ar_ready_i.value = 0

    await send_r_for_pcs(dut, [held_addr])
    await wait_cycles(dut, 3)
    assert int(dut.if_id_valid_o.value) == 0

    new_pcs = await accept_ar(dut, 1)
    assert new_pcs[0] == target_pc


@cocotb.test()
async def parameterized_depth_smoke(dut):
    await start_clock(dut)
    boot_pc = 0x8000_B000
    await reset_dut(dut, boot_pc)

    pcs = []
    got = []
    for _ in range(8):
        next_pc = (await accept_ar(dut, 1))[0]
        pcs.append(next_pc)
        await send_r_for_pcs(dut, [next_pc])
        got.extend(await collect_fetches(dut, 1))

    expected_pcs = [boot_pc + 4 * i for i in range(8)]
    assert pcs == expected_pcs
    assert got == [(pc, instr_for_pc(pc)) for pc in expected_pcs]


@cocotb.test()
async def randomized_ready_redirect_smoke(dut):
    await start_clock(dut)
    rng = random.Random(env_int("IF_STAGE_RANDOM_SEED", 0x1F57A6E))
    boot_pc = 0x8000_C000
    next_redirect_pc = 0x8001_0000
    active_epoch = 0
    outstanding = deque()
    expected_fetches = deque()

    await reset_dut(dut, boot_pc)

    for cycle in range(env_int("IF_STAGE_RANDOM_CYCLES", 250)):
        await ReadWrite()

        # 随机 redirect 只在前端完全干净时触发。这样既能覆盖 redirect
        # 重新定向，又不会违反 IF 里 1-bit epoch 的顺序响应前提。
        can_redirect = (
            not outstanding
            and not expected_fetches
            and int(dut.if_id_valid_o.value) == 0
        )
        redirect = can_redirect and rng.randrange(100) < 6

        dut.redirect_valid_i.value = int(redirect)
        dut.redirect_target_pc_i.value = next_redirect_pc if redirect else 0
        dut.imem_ar_ready_i.value = int(rng.randrange(100) < 65)
        dut.if_id_ready_i.value = int(rng.randrange(100) < 70)

        if outstanding and rng.randrange(100) < 75:
            resp_pc, _ = outstanding[0]
            dut.imem_r_valid_i.value = 1
            dut.imem_r_data_i.value = instr_for_pc(resp_pc)
            dut.imem_r_resp_i.value = OKAY if rng.randrange(100) < 90 else SLVERR
        else:
            dut.imem_r_valid_i.value = 0
            dut.imem_r_data_i.value = 0
            dut.imem_r_resp_i.value = OKAY

        if redirect:
            expected_fetches.clear()

        await ReadOnly()
        ar_fire = int(dut.imem_ar_valid_o.value) and int(dut.imem_ar_ready_i.value)
        r_fire = int(dut.imem_r_valid_i.value) and int(dut.imem_r_ready_o.value)
        ar_addr = int(dut.imem_ar_addr_o.value)

        check_fetch_outputs(
            dut,
            expected_fetches,
            (
                f"cycle={cycle} redirect={int(redirect)} "
                f"outstanding={[hex(pc) + ':' + str(epoch) for pc, epoch in outstanding]} "
                f"expected={[hex(pc) for pc in expected_fetches]}"
            ),
        )

        if ar_fire:
            assert int(dut.imem_ar_prot_o.value) == 0b100
            outstanding.append((ar_addr, active_epoch))

        if r_fire:
            pc, epoch = outstanding.popleft()
            if not redirect and epoch == active_epoch:
                expected_fetches.append(pc)

        await RisingEdge(dut.clk_i)
        await NextTimeStep()

        if redirect:
            active_epoch ^= 1
            next_redirect_pc += 0x100

    dut.redirect_valid_i.value = 0
    dut.imem_ar_ready_i.value = 0
    dut.if_id_ready_i.value = 1

    while outstanding or expected_fetches:
        await ReadWrite()
        if outstanding:
            resp_pc, _ = outstanding[0]
            dut.imem_r_valid_i.value = 1
            dut.imem_r_data_i.value = instr_for_pc(resp_pc)
            dut.imem_r_resp_i.value = OKAY
        else:
            dut.imem_r_valid_i.value = 0
            dut.imem_r_data_i.value = 0

        await ReadOnly()
        r_fire = int(dut.imem_r_valid_i.value) and int(dut.imem_r_ready_o.value)
        check_fetch_outputs(
            dut,
            expected_fetches,
            (
                f"drain outstanding="
                f"{[hex(pc) + ':' + str(epoch) for pc, epoch in outstanding]} "
                f"expected={[hex(pc) for pc in expected_fetches]}"
            ),
        )

        if r_fire:
            pc, epoch = outstanding.popleft()
            if epoch == active_epoch:
                expected_fetches.append(pc)

        await RisingEdge(dut.clk_i)
        await NextTimeStep()
