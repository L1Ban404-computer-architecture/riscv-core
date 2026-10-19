#pragma once

#include <cstdio>
#include <string>

#include "branch.hpp"

class BranchTraceReader {
 public:
  BranchTraceReader() = default;
  BranchTraceReader(const BranchTraceReader &) = delete;
  BranchTraceReader &operator=(const BranchTraceReader &) = delete;
  ~BranchTraceReader();

  void Open(const char *path);
  // 正常 EOF 返回 false；I/O 错误和非法轨迹抛出 runtime_error。
  bool Next(BranchRecord *record);

 private:
  std::FILE *file_ = nullptr;
  std::string path_;
};
