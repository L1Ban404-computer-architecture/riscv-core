#include "bht.hpp"

#include <stdexcept>

Bht::Bht(const std::string &method, std::uint32_t entries) {
  if (method == "not-taken") method_ = Method::kNotTaken;
  else if (method == "btfn") method_ = Method::kBtfn;
  else if (method == "bimodal") {
    method_ = Method::kBimodal;
    if (entries == 0 || (entries & (entries - 1u)) != 0) {
      throw std::invalid_argument("bht-entries must be a positive power of two");
    }
    // 00/01 预测不跳转，10/11 预测跳转；冷启动为弱不跳转。
    counters_.assign(entries, 1);
  } else throw std::invalid_argument("bht must be not-taken, btfn or bimodal");
}

bool Bht::Predict(std::uint32_t pc, bool backward) const {
  if (method_ == Method::kBtfn) return backward;
  return method_ == Method::kBimodal && counters_[Index(pc)] >= 2;
}

void Bht::Update(std::uint32_t pc, bool taken) {
  if (method_ != Method::kBimodal) return;
  std::uint8_t &counter = counters_[Index(pc)];
  if (taken && counter < 3) ++counter;
  if (!taken && counter > 0) --counter;
}

std::uint64_t Bht::StorageBits() const {
  return static_cast<std::uint64_t>(counters_.size()) * 2u;
}

std::size_t Bht::Index(std::uint32_t pc) const {
  return (pc >> 2) & (counters_.size() - 1u);
}
