#pragma once

#include <cstdint>
#include <cstdio>
#include <string>

#include "riscv_insttrace.h"

struct TraceRecord {
  std::uint32_t pc = 0;
  std::uint32_t instr = 0;
  std::uint32_t target = 0;
  std::uint8_t kind = RV_INSTTRACE_KIND_NONE;
  bool taken = false;
};

// 分支预测回放使用的退休指令流读取器。
class TraceReader {
 public:
  TraceReader() = default;
  TraceReader(const TraceReader &) = delete;
  TraceReader &operator=(const TraceReader &) = delete;
  ~TraceReader();

  void Open(const char *path);
  // 正常 EOF 返回 false；I/O 错误和非法轨迹抛出 runtime_error。
  bool Next(TraceRecord *record);

 private:
  [[noreturn]] void Fail(const char *message) const;

  std::FILE *file_ = nullptr;
  std::string path_;
  std::uint32_t gpr_count_ = 0;
};
