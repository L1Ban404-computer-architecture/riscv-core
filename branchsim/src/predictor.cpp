#include "predictor.hpp"

Prediction Predict(std::uint32_t pc, const Bht &bht, const Btb &btb, const Ras *ras,
                   const Btb *jump_btb, bool jump_first) {
  BtbPrediction entry = btb.Lookup(pc);
  Prediction prediction;
  if (jump_btb != nullptr) {
    const auto jump = jump_btb->Lookup(pc);
    prediction.btb_conflict = entry.hit && jump.hit;
    // 按标签命中仲裁，不用当前指令类型或真实结果选择表。
    // 即使胜出的 BRANCH 预测不跳转或 RET 遇到空栈，也不改选另一表。
    if (jump.hit && (jump_first || !entry.hit)) entry = jump;
  }
  prediction.btb_hit = entry.hit;
  if (!entry.hit) return prediction;
  if (entry.type == BtbType::kReturn) {
    if (ras != nullptr && !ras->Empty()) {
      prediction.taken = prediction.ras = true;
      prediction.target = ras->Top(pc);
    }
    return prediction;
  }
  if (entry.type == BtbType::kJal || bht.Predict(pc, entry.backward)) {
    prediction.taken = true;
    prediction.target = entry.target;
  }
  return prediction;
}

void Update(const BranchRecord &record, Bht &bht, Btb &btb, Ras *ras, bool train_returns,
            Btb *jump_btb) {
  const auto &input = record.input;
  const auto &outcome = record.outcome;
  Btb &jumps = jump_btb == nullptr ? btb : *jump_btb;
  if (IsBranch(input.instr)) {
    bht.Update(input.pc, outcome.target, outcome.taken);
    btb.Update(input.pc, outcome.target, BtbType::kBranch);
  } else if (IsJal(input.instr)) {
    jumps.Update(input.pc, outcome.target, BtbType::kJal);
  } else if (ras != nullptr && ras->Enabled() && train_returns && IsRasReturn(input.instr)) {
    jumps.Update(input.pc, 0, BtbType::kReturn);
  }
  if (ras != nullptr) ras->Update(input);
}

void BranchStats::Observe(const Prediction &prediction,
                          const BranchOutcome &outcome, bool is_control_flow) {
  const bool direction_hit = prediction.taken == outcome.taken;
  const bool hit = direction_hit &&
                   (!outcome.taken || prediction.target == outcome.target);
  total.Observe(hit);
  (is_control_flow ? control_flow : non_control_flow).Observe(hit);
  (outcome.taken ? actual_taken : actual_not_taken).Observe(hit);
  (prediction.taken ? predicted_taken : predicted_not_taken).Observe(hit);
  direction_hits += direction_hit ? 1u : 0u;
}
