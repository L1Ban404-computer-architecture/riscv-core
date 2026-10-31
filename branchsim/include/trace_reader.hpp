#pragma once

#include <cstdint>
#include "insttrace_reader.hpp"

#include "riscv_insttrace.h"

struct TraceRecord {
  std::uint32_t pc = 0;
  std::uint32_t instr = 0;
  std::uint32_t target = 0;
  std::uint8_t kind = RV_INSTTRACE_KIND_NONE;
  bool taken = false;
};

// 分支语义层：二进制帧由本目录的读取器校验。
class TraceReader {
 public:
  void Open(const char *path) { reader_.Open(path); }
  bool Next(TraceRecord *record);

 private:
  insttrace::Reader reader_;
};
