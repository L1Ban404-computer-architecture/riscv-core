#include "predictor.hpp"

Prediction Predict(const BranchInput &input, const Bht &bht,
                   const Btb &btb, const Ras &ras) {
  if (IsReturn(input.instr)) {
    const auto target = ras.Peek();
    return target ? Prediction{true, *target} : Prediction{};
  }
  if (IsJalr(input.instr)) return {};

  const BtbPrediction entry = btb.Lookup(input.pc);
  if (!entry.hit) return {};
  if (entry.type == BtbType::kJal) return {true, entry.target};
  return {bht.Predict(input.pc, entry.target), entry.target};
}

void Update(const BranchRecord &record, Bht &bht, Btb &btb, Ras &ras) {
  const auto &input = record.input;
  const auto &outcome = record.outcome;
  if (IsBranch(input.instr)) {
    bht.Update(input.pc, outcome.target, outcome.taken);
    btb.Update(input.pc, outcome.target, BtbType::kBranch);
  } else if (IsJal(input.instr)) {
    btb.Update(input.pc, outcome.target, BtbType::kJal);
  }

  // 包括预测失败和 BTB 冷启动的真实调用；JALR 调用也要维护返回栈。
  if (outcome.taken) {
    if (IsReturn(input.instr)) ras.Pop();
    else if (IsCall(input.instr)) ras.Push(input.pc + 4u);
  }
}

void BranchStats::Observe(const Prediction &prediction,
                          const BranchOutcome &outcome) {
  const bool direction_hit = prediction.taken == outcome.taken;
  const bool hit = direction_hit &&
                   (!outcome.taken || prediction.target == outcome.target);
  total.Observe(hit);
  (outcome.taken ? actual_taken : actual_not_taken).Observe(hit);
  (prediction.taken ? predicted_taken : predicted_not_taken).Observe(hit);
  direction_hits += direction_hit ? 1u : 0u;
}
