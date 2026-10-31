#include "bht.hpp"

#include <stdexcept>
#include <vector>

namespace {

class NotTakenBht final : public Bht {
 public:
  bool Predict(std::uint32_t, bool) const override { return false; }
  void Update(std::uint32_t, bool) override {}
};

class BtfnBht final : public Bht {
 public:
  bool Predict(std::uint32_t, bool backward) const override { return backward; }
  void Update(std::uint32_t, bool) override {}
};

class BimodalBht final : public Bht {
 public:
  explicit BimodalBht(std::uint32_t entries) {
    if (entries == 0 || (entries & (entries - 1u)) != 0) {
      throw std::invalid_argument("bht-entries must be a positive power of two");
    }
    // 00/01 预测不跳转，10/11 预测跳转；冷启动为弱不跳转。
    counters_.assign(entries, 1);
  }

  bool Predict(std::uint32_t pc, bool) const override {
    return counters_[Index(pc)] >= 2;
  }

  void Update(std::uint32_t pc, bool taken) override {
    std::uint8_t &counter = counters_[Index(pc)];
    if (taken && counter < 3) ++counter;
    if (!taken && counter > 0) --counter;
  }

  std::uint64_t StorageBits() const override {
    return static_cast<std::uint64_t>(counters_.size()) * 2u;
  }

 private:
  std::size_t Index(std::uint32_t pc) const {
    return (pc >> 2) & (counters_.size() - 1u);
  }

  std::vector<std::uint8_t> counters_;
};

}  // namespace

std::unique_ptr<Bht> MakeBht(const std::string &method, std::uint32_t entries) {
  if (method == "not-taken") return std::make_unique<NotTakenBht>();
  if (method == "btfn") return std::make_unique<BtfnBht>();
  if (method == "bimodal") return std::make_unique<BimodalBht>(entries);
  throw std::invalid_argument("bht must be not-taken, btfn or bimodal");
}
