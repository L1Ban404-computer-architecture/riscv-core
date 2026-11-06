#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// 静态策略不保存状态；只有 Bimodal 分配两位饱和计数器。
class Bht {
 public:
  Bht(const std::string &method, std::uint32_t entries);
  bool Predict(std::uint32_t pc, bool backward) const;
  void Update(std::uint32_t pc, bool taken);
  std::uint64_t StorageBits() const;

 private:
  enum class Method { kNotTaken, kBtfn, kBimodal };
  std::size_t Index(std::uint32_t pc) const;

  Method method_;
  std::uint32_t index_mask_ = 0;
  std::vector<std::uint8_t> counters_;
};
