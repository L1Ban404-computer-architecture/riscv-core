#include "trace.hpp"

#include <cstring>
#include <stdexcept>

#include "riscv_btrace.h"

namespace {

std::uint32_t ReadU32(const unsigned char *bytes) {
  return static_cast<std::uint32_t>(bytes[0]) |
         (static_cast<std::uint32_t>(bytes[1]) << 8) |
         (static_cast<std::uint32_t>(bytes[2]) << 16) |
         (static_cast<std::uint32_t>(bytes[3]) << 24);
}

}  // namespace

BranchTraceReader::~BranchTraceReader() {
  if (file_ != nullptr) std::fclose(file_);
}

void BranchTraceReader::Open(const char *path) {
  if (file_ != nullptr) std::fclose(file_);
  path_ = path;
  file_ = std::fopen(path, "rb");
  if (file_ == nullptr) throw std::runtime_error("cannot open btrace " + path_);
  unsigned char header[RV_BTRACE_HEADER_SIZE];
  if (std::fread(header, 1, sizeof(header), file_) != sizeof(header)) {
    throw std::runtime_error("missing/truncated btrace header: " + path_ +
                             "; regenerate with make btrace");
  }
  if (std::memcmp(header, RV_BTRACE_MAGIC, 4) != 0) {
    throw std::runtime_error("invalid/legacy btrace: " + path_ +
                             "; regenerate with make btrace");
  }
  const unsigned version = header[4] | (static_cast<unsigned>(header[5]) << 8);
  const unsigned size = header[6] | (static_cast<unsigned>(header[7]) << 8);
  if (version != RV_BTRACE_VERSION || size != RV_BTRACE_RECORD_SIZE) {
    throw std::runtime_error("unsupported btrace version/record size: " + path_);
  }
}

bool BranchTraceReader::Next(BranchRecord *record) {
  if (file_ == nullptr) throw std::runtime_error("btrace is not open");
  unsigned char bytes[RV_BTRACE_RECORD_SIZE];
  const std::size_t n = std::fread(bytes, 1, sizeof(bytes), file_);
  if (std::ferror(file_) != 0) throw std::runtime_error("cannot read btrace " + path_);
  if (n == 0) return false;
  if (n != sizeof(bytes)) throw std::runtime_error("truncated btrace record: " + path_);

  const std::uint32_t instr = ReadU32(bytes + 4);
  if (bytes[12] > 1 || (!IsBranch(instr) && !IsJal(instr) && !IsJalr(instr)) ||
      (!IsBranch(instr) && bytes[12] != 1)) {
    throw std::runtime_error("invalid btrace record: " + path_);
  }
  *record = {{ReadU32(bytes), instr}, {ReadU32(bytes + 8), bytes[12] != 0}};
  return true;
}
