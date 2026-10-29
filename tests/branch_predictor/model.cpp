// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

#include "Vbranch_predictor_test_top.h"
#include "predictor.hpp"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <random>

#ifndef TEST_SETS
#define TEST_SETS 1
#endif
#ifndef TEST_WAYS
#define TEST_WAYS 4
#endif
#ifndef TEST_BHT
#define TEST_BHT 16
#endif

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vbranch_predictor_test_top dut;
  const BtbConfig config{"table", TEST_SETS, TEST_WAYS, "rr", 8, 16};
  auto btb = std::make_unique<Btb>(config);
  auto bht = MakeBht("bimodal", TEST_BHT);
  std::mt19937 random(0x425442);
  std::uint64_t checks = 0;
  auto tick = [&]() {
    dut.clk_i = 0;
    dut.eval();
    dut.clk_i = 1;
    dut.eval();
    dut.clk_i = 0;
    dut.eval();
  };
  auto reset_model = [&]() {
    btb = std::make_unique<Btb>(config);
    bht = MakeBht("bimodal", TEST_BHT);
  };
  auto check = [&](std::uint32_t pc) {
    dut.pc_i = pc;
    dut.eval();
    const Prediction expected = dut.invalidate_i ? Prediction{} : Predict(pc, *bht, *btb);
    if (dut.taken_o != expected.taken || dut.target_o != expected.target ||
        dut.disabled_taken_o || dut.disabled_target_o) {
      std::cerr << "prediction mismatch at check " << checks << " pc=0x" << std::hex << pc
                << " got=" << dut.taken_o << ":" << dut.target_o << " expected="
                << expected.taken << ":" << expected.target << '\n';
      std::exit(1);
    }
    ++checks;
  };
  auto train = [&](std::uint32_t pc, std::uint32_t target, bool taken, bool jal) {
    dut.update_valid_i = 1;
    dut.update_pc_i = pc;
    dut.update_target_i = target;
    dut.update_taken_i = taken;
    dut.update_jal_i = jal;
    check(pc);  // 同拍查询须读旧状态，不能旁路正在写入的训练。
    tick();
    btb->Update(pc, target, jal ? BtbType::kJal : BtbType::kBranch);
    if (!jal) bht->Update(pc, target, taken);
    dut.update_valid_i = 0;
    check(pc);
    check(pc ^ 0x10000400);  // 同标签别名、高位由查询 PC 重建。
  };
  dut.rst_ni = 0;
  tick();
  dut.rst_ni = 1;
  check(0x30000100);
  // 饱和、迟滞、分支/JAL 类型切换，以及目标 bit 1 的保存。
  for (int i = 0; i < 6; ++i) train(0x30000100, 0x30000202, true, false);
  for (int i = 0; i < 6; ++i) train(0x30000100, 0x30000202, false, false);
  train(0x30000100, 0x80001234, true, true);
  train(0x30000500, 0x80005678, false, false);
  // BHT 历史在 BTB 淘汰后保留；命中训练不得改变 RR 的顺序。
  for (unsigned i = 0; i < 32; ++i) {
    train(0x30000000 + i * 4, 0x30000800 + i * 4, true, i % 3 == 0);
    train(0x30000000 + i * 4, 0x30000900 + i * 4, false, false);
  }
  for (unsigned cycle = 0; cycle < 10000; ++cycle) {
    dut.invalidate_i = cycle % 211 == 0;
    dut.rst_ni = cycle % 997 != 0;
    dut.update_valid_i = random() % 4 != 0;
    // 热点 PC + 全标签空间，混合命中、冲突、空路与 RR 淘汰。
    dut.update_pc_i = 0x30000000 | ((random() % 3 ? random() % 16 : random() % 256) << 2);
    dut.update_target_i = random() & ~1u;
    dut.update_taken_i = random() % 4 != 0;
    dut.update_jal_i = random() % 5 == 0;
    for (unsigned tag = 0; tag < 256; ++tag) check(0x80000000 | (tag << 2));
    tick();
    if (!dut.rst_ni || dut.invalidate_i) reset_model();
    else if (dut.update_valid_i) {
      const auto pc = dut.update_pc_i, target = dut.update_target_i;
      btb->Update(pc, target, dut.update_jal_i ? BtbType::kJal : BtbType::kBranch);
      if (!dut.update_jal_i) bht->Update(pc, target, dut.update_taken_i);
    }
    check(dut.update_pc_i);
  }
  dut.final();
  std::cout << "PASS: " << TEST_SETS << "x" << TEST_WAYS << " bimodal[" << TEST_BHT
            << "] " << checks << " RTL/branchsim comparisons; disabled/reset/invalidate\n";
}
