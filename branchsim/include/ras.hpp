#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

struct RasConfig {
  std::string method = "stack";
  std::uint32_t depth = 16;
};

class Ras {
 public:
  explicit Ras(const RasConfig &config);
  std::optional<std::uint32_t> Peek() const;
  void Push(std::uint32_t address);
  void Pop();

 private:
  std::vector<std::uint32_t> entries_;
  std::size_t next_ = 0;
  std::size_t count_ = 0;
};
