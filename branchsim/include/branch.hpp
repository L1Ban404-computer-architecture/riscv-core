#pragma once

#include <cstdint>

struct BranchInput {
  std::uint32_t pc = 0;
  std::uint32_t instr = 0;
};

struct BranchOutcome {
  std::uint32_t target = 0;
  bool taken = false;
};

struct BranchRecord {
  BranchInput input;
  BranchOutcome outcome;
};

inline bool IsBranch(std::uint32_t instr) {
  const std::uint32_t funct3 = (instr >> 12) & 7u;
  return (instr & 0x7fu) == 0x63u && funct3 != 2 && funct3 != 3;
}

inline bool IsJal(std::uint32_t instr) { return (instr & 0x7fu) == 0x6fu; }
inline bool IsJalr(std::uint32_t instr) { return (instr & 0x707fu) == 0x67u; }
