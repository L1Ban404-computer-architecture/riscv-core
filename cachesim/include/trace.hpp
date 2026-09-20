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

  bool Open(const std::string &path);
  /** @brief 读出下一个 PC。到达文件末尾返回 false；长度不是 4 的倍数时失败。 */
  bool Next(std::uint32_t *pc, std::string *error);

 private:
  std::FILE *file_ = nullptr;
  std::string path_;
};
