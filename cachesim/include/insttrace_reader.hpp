#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>

#include "riscv_insttrace.h"

namespace insttrace {

inline std::uint16_t ReadU16(const unsigned char *bytes) {
  return static_cast<std::uint16_t>(bytes[0]) |
         (static_cast<std::uint16_t>(bytes[1]) << 8);
}

inline std::uint32_t ReadU32(const unsigned char *bytes) {
  return static_cast<std::uint32_t>(bytes[0]) |
         (static_cast<std::uint32_t>(bytes[1]) << 8) |
         (static_cast<std::uint32_t>(bytes[2]) << 16) |
         (static_cast<std::uint32_t>(bytes[3]) << 24);
}

struct Record {
  std::uint32_t pc = 0;
  std::uint32_t instr = 0;
  std::uint32_t next_pc = 0;
  std::uint32_t target = 0;
  std::uint8_t kind = RV_INSTTRACE_KIND_NONE;
  bool taken = false;
};

// 二进制格式层：校验帧和字段编码，调用方负责领域语义。
class Reader {
 public:
  Reader() = default;
  Reader(const Reader &) = delete;
  Reader &operator=(const Reader &) = delete;
  ~Reader() { if (file_ != nullptr) std::fclose(file_); }

  void Open(const char *path) {
    if (file_ != nullptr) std::fclose(file_);
    path_ = path;
    file_ = std::fopen(path, "rb");
    if (file_ == nullptr) Fail("cannot open insttrace");
    unsigned char bytes[RV_INSTTRACE_HEADER_SIZE];
    if (std::fread(bytes, 1, sizeof(bytes), file_) != sizeof(bytes)) {
      if (std::ferror(file_) != 0) Fail("cannot read insttrace header");
      Fail("missing/truncated insttrace header");
    }
    if (std::memcmp(bytes, RV_INSTTRACE_MAGIC, 4) != 0) Fail("invalid/legacy insttrace");
    if (ReadU16(bytes + 4) != RV_INSTTRACE_VERSION ||
        ReadU16(bytes + 6) != RV_INSTTRACE_HEADER_SIZE ||
        ReadU16(bytes + 8) != RV_INSTTRACE_RECORD_SIZE || bytes[10] != 32 || bytes[11] != 4) {
      Fail("unsupported insttrace version/layout");
    }
    gpr_count_ = ReadU32(bytes + 12);
    if (gpr_count_ != 16 && gpr_count_ != 32) Fail("invalid insttrace GPR count");
  }

  bool Next(Record *record) {
    if (file_ == nullptr) Fail("insttrace is not open");
    unsigned char bytes[RV_INSTTRACE_RECORD_SIZE];
    const std::size_t size = std::fread(bytes, 1, sizeof(bytes), file_);
    if (std::ferror(file_) != 0) Fail("cannot read insttrace");
    if (size == 0) return false;
    if (size != sizeof(bytes)) Fail("truncated insttrace record");
    if (bytes[24] > RV_INSTTRACE_KIND_JALR || bytes[25] > 1)
      Fail("invalid insttrace control-flow kind/taken");
    *record = {ReadU32(bytes + 8), ReadU32(bytes + 12), ReadU32(bytes + 16),
               ReadU32(bytes + 20), bytes[24], bytes[25] != 0};
    return true;
  }

  std::uint32_t GprCount() const { return gpr_count_; }
  [[noreturn]] void Fail(const char *message) const {
    throw std::runtime_error(std::string(message) + ": " + path_ +
                             "; regenerate with INSTTRACE=1");
  }

 private:
  std::FILE *file_ = nullptr;
  std::string path_;
  std::uint32_t gpr_count_ = 0;
};

}  // namespace insttrace
