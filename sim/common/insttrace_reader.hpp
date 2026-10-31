#pragma once

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <string>

#include "riscv_insttrace.h"

// 文件协议由 runner 定义；缺失时只采集 NEMU microbench train，语义由各消费者解释。
namespace insttrace {

// 已存在的轨迹直接复用；文件锁保护并发采集，成功后才发布目标文件。
void EnsureTrace(const std::filesystem::path &path);

struct Record {
  std::uint32_t pc = 0;
  std::uint32_t instr = 0;
  std::uint32_t next_pc = 0;
  std::uint32_t target = 0;
  std::uint8_t kind = RV_INSTTRACE_KIND_NONE;
  bool taken = false;
};

class Reader {
 public:
  Reader() = default;
  Reader(const Reader &) = delete;
  Reader &operator=(const Reader &) = delete;
  ~Reader();

  void Open(const char *path);
  // 正常 EOF 返回 false；I/O 错误和非法布局抛出 runtime_error。
  bool Next(Record *record);
  std::uint32_t gpr_count() const { return gpr_count_; }

 private:
  [[noreturn]] void Fail(const char *message) const;

  std::FILE *file_ = nullptr;
  std::string path_;
  std::uint32_t gpr_count_ = 0;
};

}  // namespace insttrace
