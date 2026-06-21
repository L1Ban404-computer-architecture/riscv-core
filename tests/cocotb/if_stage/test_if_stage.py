# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

from collections import deque
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, ReadWrite, NextTimeStep


READ_MONITOR_STARTED = False


def env_int(name: str, default: int) -> int:
    try:
        return int(cocotb.plusargs.get(name, default))
    except (TypeError, ValueError):
        return default


def instr_for_pc(pc: int) -> int:
    return (0x13000000 ^ ((pc >> 2) * 0x1021)) & 0xFFFFFFFF


async def read_request_monitor(dut):
    while True:
        await ReadOnly()
        if int(dut.rst_ni.value):
            assert int(dut.imem_req_wdata_o.value) == 0
            assert int(dut.imem_req_wstrb_o.value) == 0
            if int(dut.imem_req_valid_o.value):
                assert int(dut.imem_req_addr_o.value) & 0x3 == 0

        await RisingEdge(dut.clk_i)
        await NextTimeStep()


async def reset_dut(dut, boot_pc=0x8000_0000):
    global READ_MONITOR_STARTED

    dut.boot_pc_i.value = boot_pc
    dut.redirect_valid_i.value = 0
    dut.redirect_target_pc_i.value = 0
    dut.imem_req_ready_i.value = 0
    dut.imem_rsp_valid_i.value = 0
    dut.imem_rsp_rdata_i.value = 0
    dut.imem_rsp_error_i.value = 0
    dut.if_id_ready_i.value = 1
    dut.rst_ni.value = 0

    if not READ_MONITOR_STARTED:
        cocotb.start_soon(read_request_monitor(dut))
        READ_MONITOR_STARTED = True

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


async def accept_requests(dut, count, ready_pattern=None, check_stable=True):
    accepted = []
    wait_addr = None
    wait_wdata = None
    wait_wstrb = None

    for cycle in range(1000):
        ready = 1 if ready_pattern is None else int(bool(ready_pattern(cycle)))
        dut.imem_req_ready_i.value = ready

        await ReadOnly()
        valid = int(dut.imem_req_valid_o.value)
        addr = int(dut.imem_req_addr_o.value)
        wdata = int(dut.imem_req_wdata_o.value)
        wstrb = int(dut.imem_req_wstrb_o.value)

        if check_stable and wait_addr is not None:
            assert valid == 1, "request valid dropped before handshake"
            assert addr == wait_addr, "request addr changed before handshake"
            assert wdata == wait_wdata, "request wdata changed before handshake"
            assert wstrb == wait_wstrb, "request wstrb changed before handshake"

        if valid and not ready:
            if wait_addr is None:
                wait_addr = addr
                wait_wdata = wdata
                wait_wstrb = wstrb

        if valid and ready:
            accepted.append(addr)
            assert wdata == 0
            assert wstrb == 0
            wait_addr = None
            wait_wdata = None
            wait_wstrb = None
            await RisingEdge(dut.clk_i)
            await NextTimeStep()
            if len(accepted) == count:
                dut.imem_req_ready_i.value = 0
                return accepted
            continue

        await RisingEdge(dut.clk_i)
        await NextTimeStep()

    raise AssertionError(f"Timed out waiting for {count} CoreBus request handshakes")


async def send_responses_for_pcs(dut, pcs):
    for pc in pcs:
        dut.imem_rsp_rdata_i.value = instr_for_pc(pc)
        dut.imem_rsp_error_i.value = 0
        dut.imem_rsp_valid_i.value = 1

        for _ in range(1000):
            await ReadOnly()
            ready = int(dut.imem_rsp_ready_o.value)
            await RisingEdge(dut.clk_i)
            await NextTimeStep()
            if ready:
                break
        else:
            raise AssertionError("Timed out waiting for CoreBus response ready")

    dut.imem_rsp_valid_i.value = 0
    dut.imem_rsp_rdata_i.value = 0


def check_fetch_outputs(dut, expected_fetches, context=""):
    if int(dut.if_id_valid_o.value) and int(dut.if_id_ready_i.value):
        got_pc = int(dut.if_id_pc_o.value)
        assert expected_fetches, (
            f"{context}: IF/ID produced unexpected pc 0x{got_pc:08x}"
        )
        expected_pc = expected_fetches.popleft()
        got_instr = int(dut.if_id_instr_o.value)
        assert got_pc == expected_pc, (
            f"{context}: expected pc 0x{expected_pc:08x}, got 0x{got_pc:08x}"
        )
        assert got_instr == instr_for_pc(expected_pc)
        assert int(dut.if_id_debug_pc_o.value) == expected_pc
        assert int(dut.if_id_debug_instr_o.value) == instr_for_pc(expected_pc)


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

    pcs = []
    got = []
    for _ in range(4):
        pc = (await accept_requests(dut, 1))[0]
        pcs.append(pc)
        await send_responses_for_pcs(dut, [pc])
        got.extend(await collect_fetches(dut, 1))

    expected_pcs = [boot_pc + 4 * i for i in range(4)]
    assert pcs == expected_pcs
    assert got == [(pc, instr_for_pc(pc)) for pc in expected_pcs]


@cocotb.test()
async def request_valid_and_payload_hold_under_backpressure(dut):
    await start_clock(dut)
    boot_pc = 0x8000_1000
    await reset_dut(dut, boot_pc)

    pcs = []
    for _ in range(3):
        pc = (
            await accept_requests(
                dut,
                1,
                ready_pattern=lambda cycle: cycle == 4,
                check_stable=True,
            )
        )[0]
        pcs.append(pc)
        await send_responses_for_pcs(dut, [pc])

    assert pcs == [boot_pc + 4 * i for i in range(3)]


@cocotb.test()
async def single_outstanding_blocks_next_request_until_response(dut):
    await start_clock(dut)
    boot_pc = 0x8000_1800
    await reset_dut(dut, boot_pc)

    first_pc = (await accept_requests(dut, 1))[0]
    assert first_pc == boot_pc

    # 深度为 1 的 PC FIFO 已保存 PC0。在响应返回之前，即使请求端 ready
    # 持续为 1，也不能接受或展示 PC1 请求。
    dut.imem_req_ready_i.value = 1
    for _ in range(4):
        await ReadOnly()
        assert int(dut.imem_req_valid_o.value) == 0
        await RisingEdge(dut.clk_i)
        await NextTimeStep()

    # peek_fifo 支持满状态同周期 pop/push，因此 PC0 响应释放队首时，
    # holding register 中预存的 PC1 可以在同周期完成请求握手。
    dut.imem_rsp_rdata_i.value = instr_for_pc(first_pc)
    dut.imem_rsp_error_i.value = 0
    dut.imem_rsp_valid_i.value = 1
    await ReadOnly()
    assert int(dut.imem_rsp_ready_o.value) == 1
    assert int(dut.imem_req_valid_o.value) == 1
    assert int(dut.imem_req_addr_o.value) == boot_pc + 4
    second_pc = int(dut.imem_req_addr_o.value)
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    dut.imem_rsp_valid_i.value = 0
    dut.imem_req_ready_i.value = 0
    assert second_pc == boot_pc + 4
    await send_responses_for_pcs(dut, [second_pc])


@cocotb.test()
async def zero_latency_memory_response(dut):
    await start_clock(dut)
    boot_pc = 0x8000_2000
    await reset_dut(dut, boot_pc)

    expected_fetches = deque()
    accepted_pcs = []
    handshake_cycles = []
    dut.if_id_ready_i.value = 1
    dut.imem_req_ready_i.value = 1

    for cycle in range(40):
        await ReadWrite()

        accept_more = len(accepted_pcs) < 6
        dut.imem_req_ready_i.value = int(accept_more)
        req_valid = int(dut.imem_req_valid_o.value)
        req_pc = int(dut.imem_req_addr_o.value)
        if accept_more and req_valid:
            # 直接根据本周期请求产生本周期响应，不经过软件 pending 队列。
            # 这精确建模寄存器 L0 instruction buffer 的组合命中路径。
            pc = req_pc
            dut.imem_rsp_rdata_i.value = instr_for_pc(pc)
            dut.imem_rsp_valid_i.value = 1
        else:
            dut.imem_rsp_valid_i.value = 0
            dut.imem_rsp_rdata_i.value = 0

        await ReadOnly()
        req_fire = req_valid and int(dut.imem_req_ready_i.value)
        rsp_fire = int(dut.imem_rsp_valid_i.value) and int(dut.imem_rsp_ready_o.value)

        # 空的 fall-through PC FIFO 必须让同一笔请求和响应在同周期完成。
        assert req_fire == rsp_fire
        if req_fire:
            accepted_pcs.append(req_pc)
            expected_fetches.append(req_pc)
            handshake_cycles.append(cycle)

        check_fetch_outputs(dut, expected_fetches, f"zero-latency cycle={cycle}")

        await RisingEdge(dut.clk_i)
        await NextTimeStep()

        if len(accepted_pcs) >= 6 and not expected_fetches:
            break

    expected_pcs = [boot_pc + 4 * i for i in range(6)]
    assert accepted_pcs == expected_pcs
    assert all(
        later == earlier + 1
        for earlier, later in zip(handshake_cycles, handshake_cycles[1:])
    ), "zero-latency L0 hits must sustain one request/response handshake per cycle"


@cocotb.test()
async def if_id_backpressure_preserves_fetch_order(dut):
    await start_clock(dut)
    boot_pc = 0x8000_3000
    await reset_dut(dut, boot_pc)

    dut.if_id_ready_i.value = 0
    pcs = []
    for _ in range(2):
        pc = (await accept_requests(dut, 1))[0]
        pcs.append(pc)
        await send_responses_for_pcs(dut, [pc])

        await ReadOnly()
        assert int(dut.if_id_valid_o.value) == 1
        assert int(dut.if_id_pc_o.value) == pcs[0]
        await RisingEdge(dut.clk_i)
        await NextTimeStep()

    third_pc = (await accept_requests(dut, 1))[0]
    pcs.append(third_pc)

    dut.imem_rsp_rdata_i.value = instr_for_pc(third_pc)
    dut.imem_rsp_error_i.value = 0
    dut.imem_rsp_valid_i.value = 1
    await wait_cycles(dut, 5)
    await ReadOnly()
    assert int(dut.imem_rsp_ready_o.value) == 0
    await RisingEdge(dut.clk_i)
    await ReadWrite()
    dut.if_id_ready_i.value = 1

    expected_fetches = deque(pcs)
    for cycle in range(20):
        await ReadOnly()
        if cycle == 0:
            assert int(dut.imem_rsp_ready_o.value) == 0, (
                "full fetch FIFO must not propagate IF/ID ready combinationally "
                "to CoreBus response ready"
            )
        rsp_fire = int(dut.imem_rsp_valid_i.value) and int(dut.imem_rsp_ready_o.value)
        check_fetch_outputs(dut, expected_fetches, "IF/ID backpressure release")
        await RisingEdge(dut.clk_i)
        await NextTimeStep()
        if rsp_fire:
            dut.imem_rsp_valid_i.value = 0
        if not expected_fetches:
            break

    assert not expected_fetches


@cocotb.test()
async def redirect_discards_old_outstanding_responses(dut):
    await start_clock(dut)
    boot_pc = 0x8000_4000
    target_pc = 0x8000_8000
    await reset_dut(dut, boot_pc)

    old_pc = (await accept_requests(dut, 1))[0]

    dut.redirect_target_pc_i.value = target_pc
    dut.redirect_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    dut.redirect_valid_i.value = 0

    # 单 outstanding 下，旧请求返回之前不能发出目标路径请求。旧响应仍需
    # 被消费，并由 epoch 机制丢弃。
    await ReadOnly()
    assert int(dut.imem_req_valid_o.value) == 0
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    await send_responses_for_pcs(dut, [old_pc])
    await wait_cycles(dut, 3)
    assert int(dut.if_id_valid_o.value) == 0

    new_pc = (await accept_requests(dut, 1))[0]
    assert new_pc == target_pc
    await send_responses_for_pcs(dut, [new_pc])
    got = await collect_fetches(dut, 1)
    assert got == [(new_pc, instr_for_pc(new_pc))]


@cocotb.test()
async def redirect_during_request_wait_preserves_core_bus_request(dut):
    await start_clock(dut)
    boot_pc = 0x8000_5000
    target_pc = 0x8000_A000
    await reset_dut(dut, boot_pc)

    dut.imem_req_ready_i.value = 0

    # 先等待 request valid 在 ready=0 的时钟沿被采样到。CoreBus 的 valid
    # 保持约束从这个采样点之后开始，而不是从同周期组合短暂可见开始。
    while True:
        await ReadOnly()
        request_wait_sampled = int(dut.imem_req_valid_o.value) and not int(
            dut.imem_req_ready_i.value
        )
        held_addr = int(dut.imem_req_addr_o.value)
        held_wdata = int(dut.imem_req_wdata_o.value)
        held_wstrb = int(dut.imem_req_wstrb_o.value)
        await RisingEdge(dut.clk_i)
        await NextTimeStep()
        if request_wait_sampled:
            break

    assert held_addr == boot_pc

    dut.redirect_target_pc_i.value = target_pc
    dut.redirect_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()

    assert int(dut.imem_req_valid_o.value) == 1
    assert int(dut.imem_req_addr_o.value) == held_addr
    assert int(dut.imem_req_wdata_o.value) == held_wdata
    assert int(dut.imem_req_wstrb_o.value) == held_wstrb

    dut.redirect_valid_i.value = 0
    dut.imem_req_ready_i.value = 1
    await RisingEdge(dut.clk_i)
    await NextTimeStep()
    dut.imem_req_ready_i.value = 0

    await send_responses_for_pcs(dut, [held_addr])
    await wait_cycles(dut, 3)
    assert int(dut.if_id_valid_o.value) == 0

    new_pcs = await accept_requests(dut, 1)
    assert new_pcs[0] == target_pc


@cocotb.test()
async def parameterized_depth_smoke(dut):
    await start_clock(dut)
    boot_pc = 0x8000_B000
    await reset_dut(dut, boot_pc)

    pcs = []
    got = []
    for _ in range(8):
        next_pc = (await accept_requests(dut, 1))[0]
        pcs.append(next_pc)
        await send_responses_for_pcs(dut, [next_pc])
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
            and int(dut.imem_req_valid_o.value) == 0
            and int(dut.redirect_valid_i.value) == 0
        )
        redirect = can_redirect and rng.randrange(100) < 6

        dut.redirect_valid_i.value = int(redirect)
        dut.redirect_target_pc_i.value = next_redirect_pc if redirect else 0
        dut.imem_req_ready_i.value = int(rng.randrange(100) < 65)
        dut.if_id_ready_i.value = int(rng.randrange(100) < 70)

        if outstanding and rng.randrange(100) < 75:
            resp_pc, _ = outstanding[0]
            dut.imem_rsp_valid_i.value = 1
            dut.imem_rsp_rdata_i.value = instr_for_pc(resp_pc)
            dut.imem_rsp_error_i.value = int(rng.randrange(100) >= 90)
        else:
            dut.imem_rsp_valid_i.value = 0
            dut.imem_rsp_rdata_i.value = 0
            dut.imem_rsp_error_i.value = 0

        if redirect:
            expected_fetches.clear()

        await ReadOnly()
        req_fire = int(dut.imem_req_valid_o.value) and int(dut.imem_req_ready_i.value)
        rsp_fire = int(dut.imem_rsp_valid_i.value) and int(dut.imem_rsp_ready_o.value)
        req_addr = int(dut.imem_req_addr_o.value)

        check_fetch_outputs(
            dut,
            expected_fetches,
            (
                f"cycle={cycle} redirect={int(redirect)} "
                f"outstanding={list(outstanding)} expected={list(expected_fetches)}"
            ),
        )

        # 同一个时钟沿先完成旧响应的队首 pop，再加入新请求。两者同时
        # fire 表示深度为 1 的 FIFO 原地替换，outstanding 数量仍为 1。
        if rsp_fire:
            pc, epoch = outstanding.popleft()
            if not redirect and epoch == active_epoch:
                expected_fetches.append(pc)

        if req_fire:
            assert len(outstanding) < 1, "depth-1 IF accepted a second outstanding request"
            assert int(dut.imem_req_wdata_o.value) == 0
            assert int(dut.imem_req_wstrb_o.value) == 0
            outstanding.append((req_addr, active_epoch))

        await RisingEdge(dut.clk_i)
        await NextTimeStep()

        if redirect:
            active_epoch ^= 1
            next_redirect_pc += 0x100

    dut.redirect_valid_i.value = 0
    dut.imem_req_ready_i.value = 0
    dut.if_id_ready_i.value = 1

    while outstanding or expected_fetches:
        await ReadWrite()
        if outstanding:
            resp_pc, _ = outstanding[0]
            dut.imem_rsp_valid_i.value = 1
            dut.imem_rsp_rdata_i.value = instr_for_pc(resp_pc)
            dut.imem_rsp_error_i.value = 0
        else:
            dut.imem_rsp_valid_i.value = 0
            dut.imem_rsp_rdata_i.value = 0

        await ReadOnly()
        rsp_fire = int(dut.imem_rsp_valid_i.value) and int(dut.imem_rsp_ready_o.value)
        check_fetch_outputs(
            dut,
            expected_fetches,
            (
                f"drain outstanding="
                f"{[hex(pc) + ':' + str(epoch) for pc, epoch in outstanding]} "
                f"expected={[hex(pc) for pc in expected_fetches]}"
            ),
        )

        if rsp_fire:
            pc, epoch = outstanding.popleft()
            if epoch == active_epoch:
                expected_fetches.append(pc)

        await RisingEdge(dut.clk_i)
        await NextTimeStep()
