#pragma once

#include <cstdint>
#include <cstdio>
#include <string>

/** @brief 读取 runner --pctrace 写出的小端 uint32 PC 流。 */
class PcTraceReader {
 public:
  PcTraceReader() = default;
  PcTraceReader(const PcTraceReader &) = delete;
  PcTraceReader &operator=(const PcTraceReader &) = delete;
  ~PcTraceReader();

  void Open(const char *path);
  /** @brief 读出下一个 PC。文件结束返回 false。 */
  bool Next(std::uint32_t *pc);

 private:
  std::FILE *file_ = nullptr;
  std::string path_;
};
