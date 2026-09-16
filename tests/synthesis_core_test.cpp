// Run twice (with/without SYNTHESIS); compare every cycle's functional bus trace.
#include "Vsynthesis_core_tb.h"
#include "verilated.h"
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <vector>

static constexpr std::uint32_t Boot = 0x80000000, Data = 0x80001000;
static constexpr std::uint32_t Program[] = {
    0x800010b7, // lui x1, 0x80001
    0x00000117, // auipc x2, 0
    0x0fc10113, // addi x2, x2, 252 (trap handler at Boot+0x100)
    0x30511073, // csrw mtvec, x2
    0x02a00193, // addi x3, x0, 42
    0x0030a023, // sw x3, 0(x1)
    0x0000a203, // lw x4, 0(x1)
    0x02419e63, // bne x3, x4, fail (not taken)
    0x00418463, // beq x3, x4, taken
    0x0340006f, // j fail
    0x024002ef, // jal x5, sub
    0x0000100f, // fence.i
    0x00000073, // ecall
    0xffffffff, // illegal instruction
    0x0010a203, // lw x4, 1(x1): misaligned
    0x0200a203, // lw x4, 32(x1): injected access fault
    0x05a00193, // addi x3, x0, 90
    0x0030a423, // sw x3, 8(x1): success
    0x0000006f, // j .
    0x00700313, // sub: addi x6, x0, 7
    0x0060a623, // sw x6, 12(x1)
    0x00028067, // jalr x0, x5, 0
    0xfff00193, // fail: addi x3, x0, -1
    0x0030a423, // sw x3, 8(x1)
    0x0000006f, // j .
};
static constexpr std::uint32_t Handler[] = {
    0x342023f3, // csrr x7, mcause
    0x0070a223, // sw x7, 4(x1)
    0x34102473, // csrr x8, mepc
    0x00440413, // addi x8, x8, 4
    0x34141073, // csrw mepc, x8
    0x30200073, // mret
};

struct Response {
  bool pending = false;
  unsigned due = 0;
  std::uint32_t data = 0;
  bool error = false;
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vsynthesis_core_tb top;
  // Repeat after reset with a different deterministic backpressure schedule.
  for (unsigned epoch = 0; epoch < 2; ++epoch) {
    Response imem, dmem;
    std::array<std::uint32_t, 4> memory{};
    std::vector<std::uint32_t> causes;
    unsigned invalidations = 0, i_stalls = 0, d_stalls = 0;
    for (unsigned cycle = 0; cycle < 1800; ++cycle) {
      top.clk_i = 0;
      top.rst_ni = cycle >= 4;
      top.imem_req_ready = !imem.pending && (cycle + epoch) % 4 == 0;
      top.dmem_req_ready = !dmem.pending && (cycle + epoch) % 5 == 0;
      top.imem_rsp_valid = imem.pending && cycle >= imem.due;
      top.imem_rdata = imem.data;
      top.imem_error = imem.error;
      top.dmem_rsp_valid = dmem.pending && cycle >= dmem.due;
      top.dmem_rdata = dmem.data;
      top.dmem_error = dmem.error;
      top.eval();
      // Invalid payloads have no protocol meaning and may contain stale bits.
      std::printf("%u %u %u %08x %u %u %08x %u %u %u %08x %u %u %08x %u %u %u\n",
          epoch, cycle, top.imem_req_valid,
          top.imem_req_valid ? top.imem_addr : 0,
          top.imem_req_valid ? top.imem_write : 0,
          top.imem_req_valid ? top.imem_size : 0,
          top.imem_req_valid ? top.imem_wdata : 0,
          top.imem_req_valid ? top.imem_wstrb : 0, top.imem_rsp_ready,
          top.dmem_req_valid, top.dmem_req_valid ? top.dmem_addr : 0,
          top.dmem_req_valid ? top.dmem_write : 0,
          top.dmem_req_valid ? top.dmem_size : 0,
          top.dmem_req_valid ? top.dmem_wdata : 0,
          top.dmem_req_valid ? top.dmem_wstrb : 0,
          top.dmem_rsp_ready, top.invalidate);
      if (top.rst_ni) {
        invalidations += top.invalidate;
        i_stalls += top.imem_req_valid && !top.imem_req_ready;
        d_stalls += top.dmem_req_valid && !top.dmem_req_ready;
        if (top.imem_rsp_valid && top.imem_rsp_ready) imem.pending = false;
        if (top.dmem_rsp_valid && top.dmem_rsp_ready) dmem.pending = false;
        if (top.imem_req_valid && top.imem_req_ready) {
          assert(!imem.pending && !top.imem_write && top.imem_size == 2);
          auto offset = top.imem_addr - Boot;
          assert(offset % 4 == 0);
          std::uint32_t instruction = 0;
          if (offset / 4 < std::size(Program)) instruction = Program[offset / 4];
          else {
            assert(offset >= 0x100 && (offset - 0x100) / 4 < std::size(Handler));
            instruction = Handler[(offset - 0x100) / 4];
          }
          imem = {true, cycle + 1 + (cycle + epoch) % 4, instruction, false};
        }
        if (top.dmem_req_valid && top.dmem_req_ready) {
          assert(!dmem.pending && top.dmem_size == 2);
          auto offset = top.dmem_addr - Data;
          bool error = offset == 32;
          assert(error || (offset % 4 == 0 && offset / 4 < memory.size()));
          std::uint32_t value = error ? 0 : memory[offset / 4];
          if (top.dmem_write) {
            assert(!error && top.dmem_wstrb == 15);
            memory[offset / 4] = top.dmem_wdata;
            if (offset == 4) causes.push_back(top.dmem_wdata);
          }
          dmem = {true, cycle + 2 + (cycle + epoch) % 5, value, error};
        }
      }
      top.clk_i = 1;
      top.eval();
    }
    assert(memory[0] == 42 && memory[2] == 90 && memory[3] == 7);
    assert((causes == std::vector<std::uint32_t>{11, 2, 4, 5}));
    assert(invalidations == 1 && i_stalls > 0 && d_stalls > 0);
  }
  top.final();
}
