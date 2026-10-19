#pragma once

#include <cstdint>

#include "bht.hpp"
#include "branch.hpp"
#include "btb.hpp"

struct Prediction {
  bool taken = false;
  std::uint32_t target = 0;
};

// 预测只接收 PC；指令类型和真实结果只能进入训练，结果也用于统计。
Prediction Predict(std::uint32_t pc, const Bht &bht, const Btb &btb);
void Update(const BranchRecord &record, Bht &bht, Btb &btb);

struct Accuracy {
  std::uint64_t accesses = 0;
  std::uint64_t hits = 0;
  void Observe(bool hit) {
    ++accesses;
    hits += hit ? 1u : 0u;
  }
};

struct BranchStats {
  Accuracy total;
  Accuracy actual_taken;
  Accuracy actual_not_taken;
  Accuracy predicted_taken;
  Accuracy predicted_not_taken;
  std::uint64_t direction_hits = 0;

  void Observe(const Prediction &prediction, const BranchOutcome &outcome);
};
