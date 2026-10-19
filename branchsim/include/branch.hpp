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
inline bool IsLinkRegister(std::uint32_t reg) { return reg == 1 || reg == 5; }

// 首版仅识别常规 RET，不建模协程的 pop+push 提示。
inline bool IsReturn(std::uint32_t instr) {
  return IsJalr(instr) && ((instr >> 7) & 31u) == 0 &&
         IsLinkRegister((instr >> 15) & 31u) && (instr >> 20) == 0;
}

inline bool IsCall(std::uint32_t instr) {
  return (IsJal(instr) || IsJalr(instr)) &&
         IsLinkRegister((instr >> 7) & 31u);
}
