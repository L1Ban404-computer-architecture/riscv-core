#include "trace.hpp"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

void PcTraceReader::Open(const char *path) {
  if (file_ != nullptr) std::fclose(file_);
  path_ = path;
  file_ = std::fopen(path, "rb");
  if (file_ == nullptr) {
    std::perror(path);
    std::exit(1);
  }
}

// runner --pctrace 的一条记录是小端 uint32。凑不满 4 字节就不是完整轨迹。
bool PcTraceReader::Next(std::uint32_t *pc) {
  unsigned char bytes[4];
  const std::size_t n = std::fread(bytes, 1, sizeof(bytes), file_);
  if (n == sizeof(bytes)) {
    *pc = static_cast<std::uint32_t>(bytes[0]) |
          (static_cast<std::uint32_t>(bytes[1]) << 8) |
          (static_cast<std::uint32_t>(bytes[2]) << 16) |
          (static_cast<std::uint32_t>(bytes[3]) << 24);
    return true;
  }
  if (n == 0 && std::ferror(file_) == 0) return false;
  std::fprintf(stderr, "truncated PC trace %s\n", path_.c_str());
  std::exit(1);
}

PcTraceReader::~PcTraceReader() {
  if (file_ != nullptr) std::fclose(file_);
}
