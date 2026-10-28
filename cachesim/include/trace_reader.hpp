#pragma once

#include <cstdint>
#include <cstdio>
#include <string>

class TraceReader {
 public:
  TraceReader() = default;
  TraceReader(const TraceReader &) = delete;
  TraceReader &operator=(const TraceReader &) = delete;
  ~TraceReader();

  void Open(const char *path);
  // 正常 EOF 返回 false；I/O 错误和非法轨迹抛出 runtime_error。
  bool Next(std::uint32_t *pc);

 private:
  [[noreturn]] void Fail(const char *message) const;

  std::FILE *file_ = nullptr;
  std::string path_;
};
