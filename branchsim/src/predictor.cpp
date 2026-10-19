#include "predictor.hpp"

Prediction Predict(std::uint32_t pc, const Bht &bht, const Btb &btb) {
  const BtbPrediction entry = btb.Lookup(pc);
  if (!entry.hit) return {};
  if (entry.type == BtbType::kJal || bht.Predict(pc, entry.target)) {
    return {true, entry.target};
  }
  return {};
}

void Update(const BranchRecord &record, Bht &bht, Btb &btb) {
  const auto &input = record.input;
  const auto &outcome = record.outcome;
  if (IsBranch(input.instr)) {
    bht.Update(input.pc, outcome.target, outcome.taken);
    btb.Update(input.pc, outcome.target, BtbType::kBranch);
  } else if (IsJal(input.instr)) {
    btb.Update(input.pc, outcome.target, BtbType::kJal);
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
