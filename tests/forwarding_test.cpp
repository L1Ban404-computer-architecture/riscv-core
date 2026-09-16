#include "Vforwarding_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static constexpr std::uint32_t Base1 = 0x11111111, Base2 = 0x22222222;
static constexpr std::uint32_t Ex = 0xaaaaaaaa, Mem = 0xbbbbbbbb;

struct Test {
  Vforwarding_tb dut;
  void tick() {
    dut.clk_i = 0;
    dut.eval();
    dut.clk_i = 1;
    dut.eval();
    dut.clk_i = 0;
    dut.eval();
  }
  void reset() {
    dut.rst_ni = 0;
    dut.transaction_valid_i = 1;
    dut.execute_fire_i = 0;
    dut.rs1_addr_i = 5;
    dut.rs2_addr_i = 6;
    dut.rs1_used_i = dut.rs2_used_i = 1;
    dut.rs1_value_i = Base1;
    dut.rs2_value_i = Base2;
    dut.ex_valid = dut.mem_valid = 0;
    dut.ex_data_valid = dut.mem_data_valid = 1;
    dut.ex_addr = dut.mem_addr = 5;
    dut.ex_data = Ex;
    dut.mem_data = Mem;
    tick();
    dut.rst_ni = 1;
  }
  void check(const char *name, std::uint32_t first, std::uint32_t second, bool stall) {
    dut.eval();
    if (dut.rs1_value_o != first || dut.rs2_value_o != second || dut.stall_o != stall) {
      std::fprintf(stderr, "%s: got %08x %08x stall=%u; expected %08x %08x stall=%u\n",
          name, dut.rs1_value_o, dut.rs2_value_o, dut.stall_o, first, second, stall);
      std::abort();
    }
  }
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Test t;
  auto &d = t.dut;
  // Run the same priority cases independently for each source, without a clock
  // edge that could accidentally make a held value mask a combinational error.
  for (unsigned source = 0; source < 2; ++source) {
    t.reset();
    auto check = [&](const char *name, std::uint32_t value, bool stall = false) {
      t.check(name, source == 0 ? value : Base1, source == 1 ? value : Base2, stall);
    };
    const auto base = source == 0 ? Base1 : Base2;
    d.ex_addr = d.mem_addr = source == 0 ? 5 : 6;
    check("no producer", base);
    d.ex_valid = 1;
    check("EX alone", Ex);
    d.ex_data_valid = 0;
    check("EX pending", base, true);
    d.mem_valid = 1;
    check("older MEM must not bypass pending EX", base, true);
    d.ex_data_valid = 1;
    check("EX wins both matches", Ex);
    d.mem_data_valid = 0;
    check("older pending MEM cannot stall ready EX", Ex);
    d.ex_valid = 0;
    check("MEM pending", base, true);
    d.mem_data_valid = 1;
    check("MEM alone", Mem);
    d.ex_valid = 1;
    d.ex_addr = 9;
    check("unrelated EX does not hide MEM", Mem);
    d.mem_addr = 9;
    check("unrelated producers", base);
    d.ex_addr = d.mem_addr = source == 0 ? 5 : 6;
    d.ex_data_valid = d.mem_data_valid = 0;
    if (source == 0) d.rs1_used_i = 0;
    else d.rs2_used_i = 0;
    check("unused source does not stall", base);
    if (source == 0) { d.rs1_used_i = 1; d.rs1_addr_i = 0; }
    else { d.rs2_used_i = 1; d.rs2_addr_i = 0; }
    d.ex_addr = d.mem_addr = 0;
    check("x0 preserves base and ignores producers", base);
  }

  t.reset();
  d.ex_valid = d.mem_valid = 1;
  d.ex_addr = 5;
  d.mem_addr = 6;
  t.check("independent simultaneous sources", Ex, Mem, false);
  d.ex_data_valid = 0;
  t.check("one source stalls while the other forwards", Base1, Mem, true);
  t.tick();
  d.mem_valid = 0;
  for (int i = 0; i < 3; ++i) {
    t.check("MEM value survives disappearance during stall", Base1, Mem, true);
    t.tick();
  }
  d.ex_data_valid = 1;
  t.check("pending source becomes ready", Ex, Mem, false);
  d.execute_fire_i = 1;
  t.tick();
  d.execute_fire_i = 0;
  d.ex_valid = 0;
  t.check("execution clears held value", Base1, Base2, false);

  // Both source registers may name the same destination and must both retain it.
  // Clear held values by each supported mechanism, even with a producer present.
  for (unsigned clear = 0; clear < 3; ++clear) {
    t.reset();
    d.rs2_addr_i = 5;
    d.mem_valid = 1;
    t.check("same register feeds both sources", Mem, Mem, false);
    t.tick();
    d.mem_valid = 0;
    t.check("both held values survive", Mem, Mem, false);
    d.mem_valid = 1;
    d.mem_data = Mem + 1;
    t.tick();
    d.mem_valid = 0;
    t.check("held values can be refreshed", Mem + 1, Mem + 1, false);
    d.ex_valid = 1;
    t.check("live EX overrides held values", Ex, Ex, false);
    d.ex_data_valid = 0;
    t.check("pending EX cannot use held older values", Mem + 1, Mem + 1, true);
    d.ex_valid = 0;
    d.mem_valid = 1;
    if (clear == 0) d.transaction_valid_i = 0;
    if (clear == 1) d.execute_fire_i = 1;
    if (clear == 2) d.rst_ni = 0;
    t.tick();
    d.transaction_valid_i = d.rst_ni = 1;
    d.execute_fire_i = d.mem_valid = 0;
    t.check("clear wins over simultaneous capture", Base1, Base2, false);
  }
  d.final();
  std::puts("Forwarding priority and retained-value tests: PASS");
}
