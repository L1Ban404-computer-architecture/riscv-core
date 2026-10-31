#include "predictor.hpp"

#include <stdexcept>

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

namespace {
PredictorConfig Validate(PredictorConfig config) {
  if (config.ras_mode != "btb" && config.ras_mode != "filter" && config.ras_mode != "ideal")
    throw std::invalid_argument("ras-mode must be btb, filter or ideal");
  if (config.ras_mode == "filter" && config.ras_filter_entries == 0)
    throw std::invalid_argument("filter mode requires positive ras-filter-entries");
  if (config.ras_entries && config.ras_mode == "btb" && config.btb.method == "none")
    throw std::invalid_argument("BTB-classified RAS requires --btb table");
  if (config.btb_layout != "unified" && config.btb_layout != "split")
    throw std::invalid_argument("btb-layout must be unified or split");
  if (config.split_priority != "jump" && config.split_priority != "branch")
    throw std::invalid_argument("split-priority must be jump or branch");
  if (config.ret_priority != "ret" && config.ret_priority != "btb")
    throw std::invalid_argument("ret-priority must be ret or btb");
  if (config.ras_filter_pc_bits > 30)
    throw std::invalid_argument("ras-filter-pc-bits must be in [0, 30]");
  if (config.btb_layout == "split" && (config.btb.method != "table" || config.ras_mode == "ideal"))
    throw std::invalid_argument("split layout requires --btb table and --ras-mode btb or filter");
  return config;
}
}  // namespace

Predictor::Predictor(const PredictorConfig &config)
    : config_(Validate(config)), bht_(MakeBht(config_.bht, config_.bht_entries)),
      btb_(config_.btb), ras_(config_.ras_entries, config_.ras_target_bits),
      return_table_(ras_.Enabled() && config_.ras_mode == "filter" ? config_.ras_filter_entries : 0,
                    config_.ras_filter_pc_bits ? config_.ras_filter_pc_bits : config_.btb.pc_bits) {
  if (config_.btb_layout == "split") {
    auto jumps = config_.btb;
    jumps.sets = config_.jump_btb_sets;
    jumps.ways = config_.jump_btb_ways;
    jump_btb_ = std::make_unique<Btb>(jumps);
  }
}

Prediction Predictor::Predict(std::uint32_t pc) const {
  Prediction prediction = ::Predict(pc, *bht_, btb_, &ras_, jump_btb_.get(),
                                    config_.split_priority == "jump");
  if (return_table_.Lookup(pc)) {
    prediction.return_conflict = prediction.btb_hit;
    // 仲裁按标签命中进行；BHT 不跳转或 RAS 为空都不等于表未命中。
    if (config_.ret_priority == "ret" || !prediction.btb_hit) {
      prediction.taken = prediction.ras = !ras_.Empty();
      prediction.target = ras_.Empty() ? 0 : ras_.Top(pc);
    }
  }
  return prediction;
}

Prediction Predictor::PredictIdeal(std::uint32_t pc, bool is_return) const {
  if (config_.ras_mode != "ideal")
    throw std::logic_error("instruction oracle requires ideal RAS mode");
  auto prediction = Predict(pc);
  if (ras_.Enabled() && is_return && !ras_.Empty()) {
    prediction.taken = prediction.ras = true;
    prediction.target = ras_.Top(pc);
  }
  return prediction;
}

void Predictor::Update(const BranchRecord &record) {
  ::Update(record, *bht_, btb_, &ras_, config_.ras_mode == "btb", jump_btb_.get());
  if (IsRasReturn(record.input.instr)) return_table_.Update(record.input.pc);
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
