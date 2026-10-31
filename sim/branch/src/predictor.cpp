#include "predictor.hpp"

Prediction Predict(std::uint32_t pc, const Bht &bht, const Btb &btb) {
  const BtbPrediction entry = btb.Lookup(pc);
  if (!entry.hit) return {};
  if (entry.type == BtbType::kJal || bht.Predict(pc, entry.backward)) {
    return {true, entry.target};
  }
  return {};
}

void Update(const insttrace::Record &record, Bht &bht, Btb &btb) {
  // 类型已经过轨迹校验，训练直接消费分类结果，不再解码原始指令。
  if (record.kind == RV_INSTTRACE_KIND_BRANCH) {
    bht.Update(record.pc, record.taken);
    btb.Update(record.pc, record.target, BtbType::kBranch);
  } else if (record.kind == RV_INSTTRACE_KIND_JAL) {
    btb.Update(record.pc, record.target, BtbType::kJal);
  }
}

void BranchStats::Observe(const Prediction &prediction,
                          const insttrace::Record &record) {
  const bool direction_hit = prediction.taken == record.taken;
  const bool hit = direction_hit &&
                   (!record.taken || prediction.target == record.target);
  total.Observe(hit);
  (record.kind != RV_INSTTRACE_KIND_NONE ? control_flow : non_control_flow).Observe(hit);
  (record.taken ? actual_taken : actual_not_taken).Observe(hit);
  (prediction.taken ? predicted_taken : predicted_not_taken).Observe(hit);
  direction_hits += direction_hit ? 1u : 0u;
}
