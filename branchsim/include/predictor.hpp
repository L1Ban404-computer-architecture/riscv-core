#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include "bht.hpp"
#include "branch.hpp"
#include "btb.hpp"
#include "ras.hpp"

struct PredictorConfig {
  std::string bht = "btfn";
  std::uint32_t bht_entries = 32;
  BtbConfig btb;
  std::uint32_t ras_entries = 0;
  std::uint32_t ras_target_bits = 16;
  std::string ras_mode = "btb";
  std::uint32_t ras_filter_entries = 2;
  std::string btb_layout = "unified";
  std::uint32_t jump_btb_sets = 1;
  std::uint32_t jump_btb_ways = 2;
  std::string split_priority = "jump";
  std::string ret_priority = "ret";
  std::uint32_t ras_filter_pc_bits = 0;
};

struct Prediction {
  bool taken = false;
  std::uint32_t target = 0;
  bool ras = false;
  bool btb_conflict = false;
  bool btb_hit = false;
  bool return_conflict = false;
};

// 预测只接收 PC；指令类型和真实结果只能进入训练，结果也用于统计。
Prediction Predict(std::uint32_t pc, const Bht &bht, const Btb &btb,
                   const Ras *ras = nullptr, const Btb *jump_btb = nullptr,
                   bool jump_first = true);
void Update(const BranchRecord &record, Bht &bht, Btb &btb,
            Ras *ras = nullptr, bool train_returns = true, Btb *jump_btb = nullptr);

// 完整预测器拥有查询仲裁和训练状态；统计通过只读访问器观察。
class Predictor {
 public:
  explicit Predictor(const PredictorConfig &config);
  Prediction Predict(std::uint32_t pc) const;
  // 显式的理想识别对照，接受调用方已验证的返回类型；正常查询只接收 PC。
  Prediction PredictIdeal(std::uint32_t pc, bool is_return) const;
  void Update(const BranchRecord &record);
  const Bht &bht() const { return *bht_; }
  const Ras &ras() const { return ras_; }
  const ReturnTable &return_table() const { return return_table_; }

 private:
  PredictorConfig config_;
  std::unique_ptr<Bht> bht_;
  Btb btb_;
  std::unique_ptr<Btb> jump_btb_;
  Ras ras_;
  ReturnTable return_table_;
};

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
  Accuracy control_flow;
  Accuracy non_control_flow;
  Accuracy actual_taken;
  Accuracy actual_not_taken;
  Accuracy predicted_taken;
  Accuracy predicted_not_taken;
  std::uint64_t direction_hits = 0;

  void Observe(const Prediction &prediction, const BranchOutcome &outcome,
               bool is_control_flow = true);
};
