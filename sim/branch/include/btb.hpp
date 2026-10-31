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
  bool jal_btb = false;
  // 独立 JAL 表为全相联，沿用 policy、pc_bits 和 target_bits。
  std::uint32_t jal_btb_entries = 4;
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

  struct Table {
    std::uint32_t sets = 1;
    std::uint32_t ways = 1;
    std::vector<Entry> entries;
    std::vector<std::uint32_t> rr_next;
  };

  Table MakeTable(std::uint32_t sets, std::uint32_t ways) const;
  BtbPrediction LookupTable(std::uint32_t pc, const Table &table) const;
  std::size_t SetBegin(std::uint32_t pc, const Table &table) const;
  std::uint32_t Tag(std::uint32_t pc) const;
  BtbConfig config_;
  Table table_;
  Table jal_table_;
};
