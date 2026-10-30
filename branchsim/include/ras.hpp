#pragma once

#include <cstdint>
#include <vector>

#include "branch.hpp"

struct RasAction {
  bool pop = false;
  bool push = false;
};

// RISC-V x1/x5 隐式提示；rd == rs1 的 JALR 只 push。
RasAction DecodeRasAction(std::uint32_t instr);
bool IsRasReturn(std::uint32_t instr);

class Ras {
 public:
  explicit Ras(std::uint32_t entries = 0, std::uint32_t target_bits = 16);
  bool Enabled() const { return !entries_.empty(); }
  bool Empty() const { return count_ == 0; }
  std::uint32_t Top(std::uint32_t pc) const;
  void Update(const BranchInput &input);
  void Clear();
  std::uint64_t StorageBits() const;
  std::uint64_t overflows = 0;
  std::uint64_t underflows = 0;

 private:
  std::vector<std::uint32_t> entries_;
  std::uint32_t target_bits_;
  std::uint32_t next_ = 0;
  std::uint32_t count_ = 0;
};

// 只识别 return PC，不存目标；与小 BTB 分开，避免 return 挤占 B/J。
class ReturnTable {
 public:
  ReturnTable(std::uint32_t entries, std::uint32_t pc_bits);
  bool Lookup(std::uint32_t pc) const;
  void Update(std::uint32_t pc);
  std::uint64_t StorageBits() const;

 private:
  struct Entry { bool valid = false; std::uint32_t tag = 0; };
  std::vector<Entry> entries_;
  std::uint32_t pc_bits_;
  std::uint32_t next_ = 0;
};
