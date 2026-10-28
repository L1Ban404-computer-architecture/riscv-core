#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

enum class BtbType { kBranch, kJal };

struct BtbConfig {
  std::string method = "table";
  std::uint32_t sets = 64;
  std::uint32_t ways = 2;
  std::string policy = "rr";
  std::uint32_t pc_bits = 8;
  std::uint32_t target_bits = 16;
};

struct BtbPrediction {
  bool hit = false;
  std::uint32_t target = 0;
  BtbType type = BtbType::kBranch;
  bool backward = false;
};

class Btb {
 public:
  explicit Btb(const BtbConfig &config);
  BtbPrediction Lookup(std::uint32_t pc) const;
  void Update(std::uint32_t pc, std::uint32_t target, BtbType type);

 private:
  struct Entry {
    bool valid = false;
    std::uint32_t pc = 0;
    std::uint32_t target = 0;
    BtbType type = BtbType::kBranch;
    std::uint32_t age = 0;
    bool backward = false;
  };

  std::size_t SetBegin(std::uint32_t pc) const;
  std::uint32_t Tag(std::uint32_t pc) const;
  BtbConfig config_;
  std::vector<Entry> entries_;
  std::vector<std::uint32_t> rr_next_;
};
