#pragma once

#include <cstdint>
#include <memory>
#include <string>

// 仅统一方向预测操作；各算法自行决定是否需要表、历史或其他状态。
class Bht {
 public:
  virtual ~Bht() = default;
  virtual bool Predict(std::uint32_t pc, bool backward) const = 0;
  virtual void Update(std::uint32_t pc, bool taken) = 0;
  virtual std::uint64_t StorageBits() const { return 0; }
};

std::unique_ptr<Bht> MakeBht(const std::string &method, std::uint32_t entries);
