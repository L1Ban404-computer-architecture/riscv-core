# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

from collections import deque
from dataclasses import dataclass
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer


MASK32 = 0xFFFF_FFFF
TOHOST = 0x1000
DATA_BASE = 0x400


def u32(value):
    return value & MASK32


def sext(value, bits):
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def signed(value):
    return sext(value & MASK32, 32)


def r_type(funct7, rs2, rs1, funct3, rd, opcode=0x33):
    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | opcode
    )


def i_type(imm, rs1, funct3, rd, opcode=0x13):
    return (
        ((imm & 0xFFF) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | opcode
    )


def s_type(imm, rs2, rs1, funct3):
    imm &= 0xFFF
    return (
        (((imm >> 5) & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((imm & 0x1F) << 7)
        | 0x23
    )


def b_type(offset, rs2, rs1, funct3):
    assert offset % 2 == 0 and -4096 <= offset < 4096
    imm = offset & 0x1FFF
    return (
        (((imm >> 12) & 1) << 31)
        | (((imm >> 5) & 0x3F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | (((imm >> 1) & 0xF) << 8)
        | (((imm >> 11) & 1) << 7)
        | 0x63
    )


def u_type(value, rd, opcode):
    return (value & 0xFFFFF000) | ((rd & 0x1F) << 7) | opcode


def j_type(offset, rd):
    assert offset % 2 == 0 and -(1 << 20) <= offset < (1 << 20)
    imm = offset & 0x1F_FFFF
    return (
        (((imm >> 20) & 1) << 31)
        | (((imm >> 1) & 0x3FF) << 21)
        | (((imm >> 11) & 1) << 20)
        | (((imm >> 12) & 0xFF) << 12)
        | ((rd & 0x1F) << 7)
        | 0x6F
    )


def csr_type(csr, source, funct3, rd):
    return (
        ((csr & 0xFFF) << 20)
        | ((source & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | 0x73
    )


class Assembler:
    def __init__(self, base=0):
        self.base = base
        self.words = []
        self.labels = {}
        self.fixups = []

    @property
    def pc(self):
        return self.base + 4 * len(self.words)

    def label(self, name):
        self.labels[name] = self.pc

    def emit(self, word):
        self.words.append(word)

    def branch(self, funct3, rs1, rs2, label):
        self.fixups.append((len(self.words), "branch", label, funct3, rs1, rs2))
        self.emit(0)

    def jal(self, rd, label):
        self.fixups.append((len(self.words), "jal", label, rd))
        self.emit(0)

    def addi_label(self, rd, label):
        self.fixups.append((len(self.words), "addi_label", label, rd))
        self.emit(0)

    def resolve(self):
        for fixup in self.fixups:
            index, kind, label, *args = fixup
            pc = self.base + 4 * index
            target = self.labels[label]
            if kind == "branch":
                funct3, rs1, rs2 = args
                self.words[index] = b_type(target - pc, rs2, rs1, funct3)
            elif kind == "jal":
                (rd,) = args
                self.words[index] = j_type(target - pc, rd)
            else:
                (rd,) = args
                assert -2048 <= target < 2048
                self.words[index] = i_type(target, 0, 0, rd)
        return self.words


def build_program():
    a = Assembler()
    a.emit(i_type(DATA_BASE, 0, 0, 1))       # addi x1, x0, DATA_BASE
    a.emit(i_type(-1, 0, 0, 2))              # addi x2, x0, -1
    a.emit(s_type(1, 2, 1, 0))               # sb x2, 1(x1)
    a.emit(i_type(1, 1, 4, 3, 0x03))         # lbu x3, 1(x1)
    a.emit(i_type(1, 1, 0, 4, 0x03))         # lb x4, 1(x1)
    a.emit(r_type(0, 4, 3, 0, 10))           # add x10, x3, x4
    a.emit(i_type(0x123, 0, 0, 5))           # addi x5, x0, 0x123
    a.emit(s_type(2, 5, 1, 1))               # sh x5, 2(x1)
    a.emit(i_type(2, 1, 5, 6, 0x03))         # lhu x6, 2(x1)
    a.emit(i_type(2, 1, 1, 7, 0x03))         # lh x7, 2(x1)
    a.emit(u_type(0x12345000, 8, 0x37))       # lui x8, 0x12345
    a.emit(i_type(0x67, 8, 0, 8))            # addi x8, x8, 0x67
    a.emit(s_type(4, 8, 1, 2))               # sw x8, 4(x1)
    a.emit(i_type(4, 1, 2, 9, 0x03))         # lw x9, 4(x1)
    a.emit(r_type(0, 6, 9, 0, 11))           # add x11, x9, x6 (load-use)
    a.emit(r_type(0x20, 6, 11, 0, 12))       # sub x12, x11, x6
    a.emit(i_type(3, 6, 1, 13))              # slli x13, x6, 3
    a.emit(i_type(1, 13, 5, 14))             # srli x14, x13, 1
    a.emit(i_type((0x20 << 5) | 4, 4, 5, 15))  # srai x15, x4, 4
    a.emit(r_type(0, 3, 4, 2, 16))           # slt x16, x4, x3
    a.emit(r_type(0, 3, 4, 3, 17))           # sltu x17, x4, x3
    a.emit(r_type(0, 6, 3, 4, 18))           # xor x18, x3, x6
    a.emit(r_type(0, 6, 3, 6, 19))           # or x19, x3, x6
    a.emit(r_type(0, 6, 3, 7, 23))           # and x23, x3, x6

    a.branch(0, 3, 4, "not_taken_done")      # beq: not taken
    a.emit(i_type(7, 0, 0, 24))              # visible fall-through instruction
    a.label("not_taken_done")
    a.branch(1, 3, 4, "branch_1")            # bne: taken
    a.emit(s_type(12, 2, 1, 2))              # wrong-path store
    a.label("branch_1")
    a.branch(0, 6, 7, "branch_2")            # beq: taken
    a.emit(s_type(12, 2, 1, 2))
    a.label("branch_2")
    a.branch(4, 4, 3, "branch_3")            # blt: taken
    a.emit(s_type(12, 2, 1, 2))
    a.label("branch_3")
    a.branch(7, 4, 3, "branch_4")            # bgeu: taken
    a.emit(s_type(12, 2, 1, 2))
    a.label("branch_4")
    a.jal(20, "jal_target")
    a.emit(s_type(12, 2, 1, 2))
    a.label("jal_target")
    a.addi_label(21, "jalr_target")
    a.emit(i_type(0, 21, 0, 22, 0x67))        # jalr x22, 0(x21)
    a.emit(s_type(12, 2, 1, 2))
    a.emit(i_type(0x55, 0, 0, 25))
    a.label("jalr_target")
    a.emit(r_type(0, 22, 20, 0, 26))          # consume both link registers
    a.emit(u_type(TOHOST, 30, 0x37))
    a.emit(i_type(1, 0, 0, 31))
    a.emit(s_type(0, 31, 30, 2))              # signal successful completion
    a.emit(j_type(0, 0))                      # should not be needed by the test
    return a.resolve()


class ByteMemory:
    def __init__(self):
        self.data = {}

    def clone(self):
        other = ByteMemory()
        other.data = dict(self.data)
        return other

    def read_word(self, addr):
        addr &= ~0x3
        return sum((self.data.get(addr + lane, 0) & 0xFF) << (8 * lane) for lane in range(4))

    def write_word(self, addr, value, wstrb=0xF):
        addr &= ~0x3
        for lane in range(4):
            if (wstrb >> lane) & 1:
                self.data[addr + lane] = (value >> (8 * lane)) & 0xFF

    def load_program(self, base, words):
        for index, word in enumerate(words):
            self.write_word(base + 4 * index, word)


@dataclass
class Response:
    due: int
    addr: int
    rdata: int
    error: int = 0


class CoreBusSlave:
    def __init__(self, dut, prefix, memory, seed, ready_probability, immediate_probability, max_latency):
        self.dut = dut
        self.prefix = prefix
        self.memory = memory
        self.random = random.Random(seed)
        self.ready_probability = ready_probability
        self.immediate_probability = immediate_probability
        self.max_latency = max_latency
        self.pending = deque()
        self.cycle = 0
        self.request_count = 0
        self.response_count = 0
        self.write_log = []
        self.request_log = []
        self.response_log = []
        self.blocked_request = None
        self.blocked_response = None

        self.req_valid = getattr(dut, f"{prefix}_req_valid_o")
        self.req_ready = getattr(dut, f"{prefix}_req_ready_i")
        self.req_addr = getattr(dut, f"{prefix}_req_addr_o")
        self.req_write = getattr(dut, f"{prefix}_req_write_o")
        self.req_size = getattr(dut, f"{prefix}_req_size_o")
        self.req_wdata = getattr(dut, f"{prefix}_req_wdata_o")
        self.req_wstrb = getattr(dut, f"{prefix}_req_wstrb_o")
        self.rsp_valid = getattr(dut, f"{prefix}_rsp_valid_i")
        self.rsp_ready = getattr(dut, f"{prefix}_rsp_ready_o")
        self.rsp_rdata = getattr(dut, f"{prefix}_rsp_rdata_i")
        self.rsp_error = getattr(dut, f"{prefix}_rsp_error_i")

    def clear_inputs(self):
        self.req_ready.value = 0
        self.rsp_valid.value = 0
        self.rsp_rdata.value = 0
        self.rsp_error.value = 0

    def make_response(self, addr):
        return Response(self.cycle, addr, self.memory.read_word(addr), 0)

    async def run(self):
        self.clear_inputs()
        while True:
            await FallingEdge(self.dut.clk_i)
            if not int(self.dut.rst_ni.value):
                self.pending.clear()
                self.cycle = 0
                self.request_count = 0
                self.response_count = 0
                self.write_log.clear()
                self.request_log.clear()
                self.response_log.clear()
                self.blocked_request = None
                self.blocked_response = None
                self.clear_inputs()
                continue

            ready = self.random.random() < self.ready_probability
            self.req_ready.value = ready
            response = None
            response_from_queue = False
            immediate = False

            if self.pending and self.pending[0].due <= self.cycle:
                response = self.pending[0]
                response_from_queue = True

            self.rsp_valid.value = response is not None
            self.rsp_rdata.value = 0 if response is None else response.rdata
            self.rsp_error.value = 0 if response is None else response.error
            # A queued response can pop a full metadata FIFO and thereby expose
            # a new request in the same cycle. Drive it before sampling req_valid.
            await Timer(1, unit="ps")

            valid = int(self.req_valid.value)
            payload = (
                int(self.req_addr.value),
                int(self.req_write.value),
                int(self.req_size.value),
                int(self.req_wdata.value),
                int(self.req_wstrb.value),
            )
            request_fire = bool(valid and ready)
            if response is None and not self.pending and request_fire:
                if self.random.random() < self.immediate_probability:
                    response = self.make_response(payload[0])
                    immediate = True
                    self.rsp_valid.value = 1
                    self.rsp_rdata.value = response.rdata
                    self.rsp_error.value = response.error
                    await Timer(1, unit="ps")
                    valid = int(self.req_valid.value)
                    payload = (
                        int(self.req_addr.value),
                        int(self.req_write.value),
                        int(self.req_size.value),
                        int(self.req_wdata.value),
                        int(self.req_wstrb.value),
                    )
                    request_fire = bool(valid and ready)

            if self.blocked_request is not None:
                assert valid, f"{self.prefix}: req_valid dropped while blocked"
                assert payload == self.blocked_request, f"{self.prefix}: request payload changed while blocked"
            if valid:
                addr, write, size, wdata, wstrb = payload
                assert size in (0, 1, 2), f"{self.prefix}: invalid request size"
                assert addr & ((1 << size) - 1) == 0, (
                    f"{self.prefix}: request address is not naturally aligned"
                )
                if not write:
                    assert wdata == 0, f"{self.prefix}: read request wdata must be zero"
                    assert wstrb == 0, f"{self.prefix}: read request wstrb must be zero"
                if self.prefix == "imem":
                    assert payload[1:] == (0, 2, 0, 0), (
                        "imem: instruction fetch must be a word read"
                    )

            response_payload = None if response is None else (response.rdata, response.error)
            if self.blocked_response is not None:
                assert response_payload is not None, f"{self.prefix}: rsp_valid dropped while blocked"
                assert response_payload == self.blocked_response, (
                    f"{self.prefix}: response payload changed while blocked"
                )
            response_fire = bool(response is not None and int(self.rsp_ready.value))

            await RisingEdge(self.dut.clk_i)

            self.blocked_request = payload if valid and not ready else None
            self.blocked_response = response_payload if response is not None and not response_fire else None
            if response_from_queue and response_fire:
                self.pending.popleft()
                self.response_count += 1
                self.response_log.append((response.addr, response.rdata))

            if request_fire:
                addr, write, size, wdata, wstrb = payload
                self.request_count += 1
                self.request_log.append(payload)
                if write:
                    self.memory.write_word(addr, wdata, wstrb)
                    self.write_log.append(payload)
                if immediate:
                    if response_fire:
                        self.response_count += 1
                        self.response_log.append((response.addr, response.rdata))
                    else:
                        self.pending.appendleft(response)
                else:
                    latency = self.random.randint(0, self.max_latency)
                    queued = self.make_response(addr)
                    queued.due = self.cycle + latency
                    self.pending.append(queued)

            assert self.response_count <= self.request_count
            assert len(self.pending) == self.request_count - self.response_count
            self.cycle += 1


@dataclass
class RetireResult:
    next_pc: int
    wb_valid: bool = False
    rd: int = 0
    wdata: int = 0
    mem_op: int = 0
    mem_size: int = 2
    mem_sign_ext: bool = False
    mem_addr: int = 0
    mem_data: int = 0
    raw_rdata: int = 0
    redirect_valid: bool = False
    redirect_target: int = 0
    done: bool = False


class Rv32iReference:
    def __init__(self, memory, boot_pc=0):
        self.memory = memory
        self.regs = [0] * 32
        self.pc = boot_pc
        self.retired = 0

    def reg(self, index):
        return 0 if index == 0 else self.regs[index]

    def execute(self, instr):
        pc = self.pc
        opcode = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        funct3 = (instr >> 12) & 7
        rs1 = (instr >> 15) & 0x1F
        rs2 = (instr >> 20) & 0x1F
        funct7 = (instr >> 25) & 0x7F
        lhs = self.reg(rs1)
        rhs = self.reg(rs2)
        result = RetireResult(next_pc=u32(pc + 4), rd=rd)

        if opcode == 0x37:                    # LUI
            result.wb_valid = True
            result.wdata = instr & 0xFFFFF000
        elif opcode == 0x17:                  # AUIPC
            result.wb_valid = True
            result.wdata = u32(pc + (instr & 0xFFFFF000))
        elif opcode == 0x6F:                  # JAL
            imm = sext(
                (((instr >> 31) & 1) << 20)
                | (((instr >> 12) & 0xFF) << 12)
                | (((instr >> 20) & 1) << 11)
                | (((instr >> 21) & 0x3FF) << 1),
                21,
            )
            result.wb_valid = True
            result.wdata = u32(pc + 4)
            result.next_pc = u32(pc + imm)
            result.redirect_valid = result.next_pc != u32(pc + 4)
            if result.redirect_valid:
                result.redirect_target = result.next_pc
        elif opcode == 0x67 and funct3 == 0:  # JALR
            imm = sext(instr >> 20, 12)
            result.wb_valid = True
            result.wdata = u32(pc + 4)
            result.next_pc = u32(lhs + imm) & ~1
            result.redirect_valid = result.next_pc != u32(pc + 4)
            if result.redirect_valid:
                result.redirect_target = result.next_pc
        elif opcode == 0x63:                  # BRANCH
            imm = sext(
                (((instr >> 31) & 1) << 12)
                | (((instr >> 7) & 1) << 11)
                | (((instr >> 25) & 0x3F) << 5)
                | (((instr >> 8) & 0xF) << 1),
                13,
            )
            taken = {
                0: lhs == rhs,
                1: lhs != rhs,
                4: signed(lhs) < signed(rhs),
                5: signed(lhs) >= signed(rhs),
                6: lhs < rhs,
                7: lhs >= rhs,
            }[funct3]
            if taken:
                result.next_pc = u32(pc + imm)
                result.redirect_valid = result.next_pc != u32(pc + 4)
                if result.redirect_valid:
                    result.redirect_target = result.next_pc
        elif opcode == 0x03:                  # LOAD
            imm = sext(instr >> 20, 12)
            addr = u32(lhs + imm)
            raw = self.memory.read_word(addr)
            shift = (addr & 3) * 8
            sizes = {0: (0, True), 1: (1, True), 2: (2, True), 4: (0, False), 5: (1, False)}
            size, sign_ext = sizes[funct3]
            if size == 0:
                value = (raw >> shift) & 0xFF
                value = sext(value, 8) if sign_ext else value
            elif size == 1:
                value = (raw >> shift) & 0xFFFF
                value = sext(value, 16) if sign_ext else value
            else:
                value = raw
            result.wb_valid = True
            result.wdata = u32(value)
            result.mem_op = 1
            result.mem_size = size
            result.mem_sign_ext = sign_ext
            result.mem_addr = addr
            result.mem_data = u32(value)
            result.raw_rdata = raw
        elif opcode == 0x23:                  # STORE
            imm = sext(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12)
            addr = u32(lhs + imm)
            size = {0: 0, 1: 1, 2: 2}[funct3]
            lane = addr & 3
            if size == 0:
                wstrb = 1 << lane
                aligned = (rhs & 0xFF) << (8 * lane)
            elif size == 1:
                wstrb = 0x3 << lane
                aligned = (rhs & 0xFFFF) << (8 * lane)
            else:
                wstrb = 0xF
                aligned = rhs
            self.memory.write_word(addr, aligned, wstrb)
            result.mem_op = 2
            result.mem_size = size
            result.mem_addr = addr
            result.mem_data = rhs
            result.done = addr == TOHOST and (rhs & MASK32) == 1
        elif opcode == 0x13:                  # OP-IMM
            imm = sext(instr >> 20, 12)
            if funct3 == 0:
                value = lhs + imm
            elif funct3 == 2:
                value = int(signed(lhs) < imm)
            elif funct3 == 3:
                value = int(lhs < u32(imm))
            elif funct3 == 4:
                value = lhs ^ u32(imm)
            elif funct3 == 6:
                value = lhs | u32(imm)
            elif funct3 == 7:
                value = lhs & u32(imm)
            elif funct3 == 1:
                value = lhs << (rs2 & 0x1F)
            elif funct3 == 5 and funct7 == 0:
                value = lhs >> (rs2 & 0x1F)
            elif funct3 == 5 and funct7 == 0x20:
                value = signed(lhs) >> (rs2 & 0x1F)
            else:
                raise AssertionError(f"unsupported OP-IMM 0x{instr:08x}")
            result.wb_valid = True
            result.wdata = u32(value)
        elif opcode == 0x33:                  # OP
            key = (funct7, funct3)
            value = {
                (0, 0): lambda: lhs + rhs,
                (0x20, 0): lambda: lhs - rhs,
                (0, 1): lambda: lhs << (rhs & 0x1F),
                (0, 2): lambda: int(signed(lhs) < signed(rhs)),
                (0, 3): lambda: int(lhs < rhs),
                (0, 4): lambda: lhs ^ rhs,
                (0, 5): lambda: lhs >> (rhs & 0x1F),
                (0x20, 5): lambda: signed(lhs) >> (rhs & 0x1F),
                (0, 6): lambda: lhs | rhs,
                (0, 7): lambda: lhs & rhs,
            }[key]()
            result.wb_valid = True
            result.wdata = u32(value)
        elif opcode == 0x0F and funct3 == 0:  # FENCE
            pass
        else:
            raise AssertionError(f"unexpected/illegal instruction 0x{instr:08x} at pc 0x{pc:08x}")

        if result.wb_valid and rd != 0:
            self.regs[rd] = result.wdata
        self.regs[0] = 0
        self.pc = result.next_pc
        self.retired += 1
        return result


def check_equal(actual, expected, description, pc, instr):
    assert actual == expected, (
        f"{description}: actual=0x{actual:x}, expected=0x{expected:x}; "
        f"pc=0x{pc:08x}, instr=0x{instr:08x}"
    )


async def reset_dut(dut):
    dut.rst_ni.value = 0
    dut.boot_pc_i.value = 0
    dut.imem_req_ready_i.value = 0
    dut.imem_rsp_valid_i.value = 0
    dut.imem_rsp_rdata_i.value = 0
    dut.imem_rsp_error_i.value = 0
    dut.dmem_req_ready_i.value = 0
    dut.dmem_rsp_valid_i.value = 0
    dut.dmem_rsp_rdata_i.value = 0
    dut.dmem_rsp_error_i.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk_i)
        await ReadOnly()
        assert int(dut.debug_state_cycle_count_o.value) == 0
        assert int(dut.debug_state_instret_count_o.value) == 0
        assert int(dut.debug_state_trap_o.value) == 0
        await Timer(1, unit="ns")
    dut.rst_ni.value = 1


async def run_program(dut, seed, ready_probability, immediate_probability, max_latency):
    program = build_program()
    memory = ByteMemory()
    memory.load_program(0, program)
    reference = Rv32iReference(memory.clone())

    imem = CoreBusSlave(
        dut, "imem", memory, seed,
        ready_probability, immediate_probability, max_latency,
    )
    dmem = CoreBusSlave(
        dut, "dmem", memory, seed ^ 0xDADA,
        ready_probability, immediate_probability, max_latency,
    )
    cocotb.start_soon(imem.run())
    cocotb.start_soon(dmem.run())
    await reset_dut(dut)

    trace = deque(maxlen=12)
    last_state_cycle = 0
    last_retire_payload = None
    for cycle in range(2000):
        await RisingEdge(dut.clk_i)
        await ReadOnly()
        if not int(dut.debug_retire_valid_o.value):
            assert int(dut.debug_state_cycle_count_o.value) == last_state_cycle
            assert int(dut.debug_state_instret_count_o.value) == reference.retired
            if last_retire_payload is not None:
                assert int(dut.debug_retire_pc_o.value) == last_retire_payload[0]
                assert int(dut.debug_retire_instr_o.value) == last_retire_payload[1]
            continue

        pc = int(dut.debug_retire_pc_o.value)
        instr = int(dut.debug_retire_instr_o.value)
        last_state_cycle = cycle + 1
        last_retire_payload = (pc, instr)
        assert int(dut.debug_state_cycle_count_o.value) == last_state_cycle
        trace.append((pc, instr))
        try:
            check_equal(pc, reference.pc, "retirement PC", pc, instr)
            check_equal(instr, reference.memory.read_word(pc), "retirement instruction", pc, instr)
            expected = reference.execute(instr)
            check_equal(
                int(dut.debug_state_instret_count_o.value), reference.retired,
                "retirement counter", pc, instr,
            )

            check_equal(int(dut.debug_retire_gpr_we_o.value), int(expected.wb_valid), "GPR write enable", pc, instr)
            if expected.wb_valid:
                check_equal(int(dut.debug_retire_gpr_waddr_o.value), expected.rd, "GPR write address", pc, instr)
                check_equal(int(dut.debug_retire_gpr_wdata_o.value), expected.wdata, "GPR write data", pc, instr)

            check_equal(int(dut.debug_retire_mem_op_o.value), expected.mem_op, "memory operation", pc, instr)
            if expected.mem_op:
                check_equal(int(dut.debug_retire_mem_size_o.value), expected.mem_size, "memory size", pc, instr)
                check_equal(int(dut.debug_retire_mem_addr_o.value), expected.mem_addr, "memory address", pc, instr)
                data_mask = {0: 0xFF, 1: 0xFFFF, 2: MASK32}[expected.mem_size]
                check_equal(
                    int(dut.debug_retire_mem_data_o.value) & data_mask,
                    expected.mem_data & data_mask,
                    "memory data", pc, instr,
                )

            check_equal(
                int(dut.debug_retire_redirect_valid_o.value), int(expected.redirect_valid),
                "redirect valid", pc, instr,
            )
            if expected.redirect_valid:
                check_equal(
                    int(dut.debug_retire_redirect_target_o.value), expected.redirect_target,
                    "redirect target", pc, instr,
                )
        except AssertionError as error:
            history = "\n".join(f"  pc=0x{p:08x} instr=0x{i:08x}" for p, i in trace)
            requests = " ".join(
                f"{addr:08x}" for addr, _, _, _, _ in imem.request_log[-16:]
            )
            responses = " ".join(f"{addr:08x}" for addr, _ in imem.response_log[-16:])
            raise AssertionError(
                f"{error}\nrecent retirement history:\n{history}"
                f"\nrecent imem requests:  {requests}"
                f"\nrecent imem responses: {responses}"
            ) from error

        if expected.done:
            assert reference.retired >= 35
            assert reference.memory.read_word(DATA_BASE + 12) == 0, "wrong-path store reached reference memory"
            assert memory.read_word(DATA_BASE + 12) == 0, "wrong-path store reached CoreBus"
            assert all(
                addr != DATA_BASE + 12 for addr, _, _, _, _ in dmem.write_log
            )
            dut._log.info(
                "program completed: seed=%d cycles=%d retired=%d imem=%d dmem=%d",
                seed, cycle + 1, reference.retired, imem.request_count, dmem.request_count,
            )
            return

    history = "\n".join(f"  pc=0x{p:08x} instr=0x{i:08x}" for p, i in trace)
    raise AssertionError(f"timeout after 2000 cycles; retired={reference.retired}\n{history}")


@cocotb.test()
async def zero_latency_core_bus_and_pipeline_flow(dut):
    """Both buses accept and respond in the same cycle on every request."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await run_program(
        dut,
        seed=0x1020,
        ready_probability=1.0,
        immediate_probability=1.0,
        max_latency=0,
    )


@cocotb.test()
async def randomized_core_bus_backpressure(dut):
    """Exercise request stalls, delayed ordered responses and occasional bypass responses."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await run_program(
        dut,
        seed=0x5EED,
        ready_probability=0.62,
        immediate_probability=0.30,
        max_latency=7,
    )


@cocotb.test()
async def csr_ecall_handler_and_mret_are_precise(dut):
    """Exercise all Zicsr forms and an ECALL/handler/MRET round trip."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())

    memory = ByteMemory()
    program = [
        i_type(0x100, 0, 0, 1),                 # addi x1, x0, 0x100
        csr_type(0x305, 1, 0b001, 2),           # csrrw x2, mtvec, x1
        i_type(3, 0, 0, 6),                     # addi x6, x0, 3
        csr_type(0x343, 6, 0b001, 7),           # csrrw x7, mtval, x6
        csr_type(0x343, 6, 0b010, 8),           # csrrs x8, mtval, x6
        csr_type(0x343, 6, 0b011, 9),           # csrrc x9, mtval, x6
        csr_type(0x343, 5, 0b101, 10),          # csrrwi x10, mtval, 5
        csr_type(0x343, 2, 0b110, 11),          # csrrsi x11, mtval, 2
        csr_type(0x343, 1, 0b111, 12),          # csrrci x12, mtval, 1
        0x00000073,                             # ecall
        i_type(7, 0, 0, 3),                     # resumed addi x3, x0, 7
        j_type(0, 0),                           # stop fetching useful work
    ]
    ecall_pc = 9 * 4
    resume_pc = ecall_pc + 4
    handler = [
        csr_type(0x341, 0, 0b010, 4),           # csrrs x4, mepc, x0
        i_type(7, 4, 0, 5),                     # request an unaligned mepc value
        csr_type(0x341, 5, 0b001, 0),           # csrrw x0, mepc, x5
        csr_type(0x341, 0, 0b010, 13),          # mepc reads back IALIGN-aligned
        0x30200073,                             # mret
    ]
    memory.load_program(0, program)
    memory.load_program(0x100, handler)

    imem = CoreBusSlave(dut, "imem", memory, 0xC5A, 0.75, 0.25, 5)
    dmem = CoreBusSlave(dut, "dmem", memory, 0xD5A, 0.75, 0.25, 5)
    cocotb.start_soon(imem.run())
    cocotb.start_soon(dmem.run())
    await reset_dut(dut)

    retired_pcs = []
    writes = {}
    csr_at_pc = {}
    for _ in range(800):
        await RisingEdge(dut.clk_i)
        await ReadOnly()
        if not int(dut.debug_retire_valid_o.value):
            continue

        pc = int(dut.debug_retire_pc_o.value)
        retired_pcs.append(pc)
        csr_at_pc[pc] = (
            int(dut.debug_retire_mstatus_o.value),
            int(dut.debug_retire_mtvec_o.value),
            int(dut.debug_retire_mepc_o.value),
            int(dut.debug_retire_mcause_o.value),
            int(dut.debug_retire_mtval_o.value),
        )
        if int(dut.debug_retire_gpr_we_o.value):
            writes[int(dut.debug_retire_gpr_waddr_o.value)] = int(
                dut.debug_retire_gpr_wdata_o.value
            )

        if pc == resume_pc:
            break
    else:
        raise AssertionError("CSR/trap program did not return from MRET")

    expected_prefix = list(range(0, ecall_pc + 4, 4)) + [
        0x100, 0x104, 0x108, 0x10C, 0x110, resume_pc
    ]
    assert retired_pcs == expected_prefix
    assert writes[2] == 0
    assert writes[7] == 0
    assert writes[8] == 3
    assert writes[9] == 3
    assert writes[10] == 0
    assert writes[11] == 5
    assert writes[12] == 7
    assert writes[4] == ecall_pc
    assert writes[13] == resume_pc
    assert writes[3] == 7

    # CSR snapshots describe architectural state after the retiring instruction.
    assert csr_at_pc[4][1] == 0x100
    assert csr_at_pc[12][4] == 3
    assert csr_at_pc[20][4] == 0
    assert csr_at_pc[24][4] == 5
    assert csr_at_pc[28][4] == 7
    assert csr_at_pc[32][4] == 6
    assert csr_at_pc[ecall_pc][2:] == (ecall_pc, 11, 0), csr_at_pc[ecall_pc]
    assert csr_at_pc[0x108][2] == resume_pc
    assert csr_at_pc[0x10C][2] == resume_pc
    assert csr_at_pc[0x110][0] & (1 << 7)


@cocotb.test()
async def synchronous_exceptions_report_precise_cause_and_tval(dut):
    """Check misaligned, illegal, breakpoint and control-target exceptions."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    memory = ByteMemory()
    program = [
        i_type(0x100, 0, 0, 1),                 # addi x1, x0, 0x100
        csr_type(0x305, 1, 0b001, 0),           # csrrw x0, mtvec, x1
        i_type(1, 0, 0b010, 3, 0x03),           # lw x3, 1(x0): misaligned
        0xFFFF_FFFF,                            # illegal instruction
        0x0010_0073,                            # ebreak
        j_type(2, 0),                           # JAL target violates IALIGN=32
        i_type(9, 0, 0, 10),                    # final visible instruction
        j_type(0, 0),
    ]
    handler = [
        csr_type(0x342, 0, 0b010, 4),           # csrr x4, mcause
        csr_type(0x343, 0, 0b010, 5),           # csrr x5, mtval
        csr_type(0x341, 0, 0b010, 6),           # csrr x6, mepc
        i_type(4, 6, 0, 6),
        csr_type(0x341, 6, 0b001, 0),
        0x3020_0073,
    ]
    memory.load_program(0, program)
    memory.load_program(0x100, handler)

    imem = CoreBusSlave(dut, "imem", memory, 0xE11, 0.70, 0.20, 6)
    dmem = CoreBusSlave(dut, "dmem", memory, 0xE22, 0.70, 0.20, 6)
    cocotb.start_soon(imem.run())
    cocotb.start_soon(dmem.run())
    await reset_dut(dut)

    expected = {
        8: (4, 1),
        12: (2, 0xFFFF_FFFF),
        16: (3, 0),
        20: (0, 22),
    }
    observed = {}
    held_trap = None
    for _ in range(1200):
        await RisingEdge(dut.clk_i)
        await ReadOnly()
        if not int(dut.debug_retire_valid_o.value):
            if held_trap is not None:
                assert int(dut.debug_state_trap_o.value) == 1
                assert int(dut.debug_state_cause_o.value) == held_trap[0]
                assert int(dut.debug_state_tval_o.value) == held_trap[1]
            continue
        pc = int(dut.debug_retire_pc_o.value)
        if pc in expected:
            observed[pc] = (
                int(dut.debug_retire_mcause_o.value),
                int(dut.debug_retire_mtval_o.value),
            )
            assert int(dut.debug_retire_gpr_we_o.value) == 0
            assert int(dut.debug_retire_mem_op_o.value) == 0
            assert int(dut.debug_state_trap_o.value) == 1
            assert int(dut.debug_state_intr_o.value) == 0
            assert int(dut.debug_state_cause_o.value) == expected[pc][0]
            assert int(dut.debug_state_tval_o.value) == expected[pc][1]
            held_trap = expected[pc]
        elif held_trap is not None:
            assert int(dut.debug_state_trap_o.value) == 0
            assert int(dut.debug_state_intr_o.value) == 0
            assert int(dut.debug_state_cause_o.value) == 0
            assert int(dut.debug_state_tval_o.value) == 0
            held_trap = None
        if pc == 24:
            assert int(dut.debug_retire_gpr_we_o.value) == 1
            assert int(dut.debug_retire_gpr_waddr_o.value) == 10
            assert int(dut.debug_retire_gpr_wdata_o.value) == 9
            assert int(dut.debug_state_trap_o.value) == 0
            assert int(dut.debug_state_intr_o.value) == 0
            assert int(dut.debug_state_cause_o.value) == 0
            assert int(dut.debug_state_tval_o.value) == 0
            break
    else:
        raise AssertionError("synchronous exception program did not complete")

    assert observed == expected
    assert all(addr != 0 for addr, _, _, _, _ in dmem.request_log)
