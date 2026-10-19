#include "bht.hpp"

#include <stdexcept>

namespace {

class NotTakenBht final : public Bht {
 public:
  bool Predict(std::uint32_t, std::uint32_t) const override { return false; }
  void Update(std::uint32_t, std::uint32_t, bool) override {}
};

class BtfnBht final : public Bht {
 public:
  bool Predict(std::uint32_t pc, std::uint32_t target) const override {
    // RV32 模 2^32 的差值，检查符号位也适用于地址空间边界附近的分支。
    return ((target - pc) & 0x80000000u) != 0;
  }
  void Update(std::uint32_t, std::uint32_t, bool) override {}
};

}  // namespace

std::unique_ptr<Bht> MakeBht(const std::string &method) {
  if (method == "not-taken") return std::make_unique<NotTakenBht>();
  if (method == "btfn") return std::make_unique<BtfnBht>();
  throw std::invalid_argument("bht must be not-taken or btfn");
}
