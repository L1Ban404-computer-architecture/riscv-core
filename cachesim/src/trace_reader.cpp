#include "trace_reader.hpp"

#include <cstring>
#include <stdexcept>

#include "riscv_insttrace.h"

namespace {

std::uint16_t ReadU16(const unsigned char *bytes) {
  return static_cast<std::uint16_t>(bytes[0]) |
         (static_cast<std::uint16_t>(bytes[1]) << 8);
}

std::uint32_t ReadU32(const unsigned char *bytes) {
  return static_cast<std::uint32_t>(bytes[0]) |
         (static_cast<std::uint32_t>(bytes[1]) << 8) |
         (static_cast<std::uint32_t>(bytes[2]) << 16) |
         (static_cast<std::uint32_t>(bytes[3]) << 24);
}

}  // namespace

TraceReader::~TraceReader() {
  if (file_ != nullptr) std::fclose(file_);
}

void TraceReader::Open(const char *path) {
  if (file_ != nullptr) std::fclose(file_);
  path_ = path;
  file_ = std::fopen(path, "rb");
  if (file_ == nullptr) Fail("cannot open insttrace");

  unsigned char bytes[RV_INSTTRACE_HEADER_SIZE];
  if (std::fread(bytes, 1, sizeof(bytes), file_) != sizeof(bytes)) {
    if (std::ferror(file_) != 0) Fail("cannot read insttrace header");
    Fail("missing/truncated insttrace header");
  }
  if (std::memcmp(bytes, RV_INSTTRACE_MAGIC, 4) != 0) {
    Fail("invalid/legacy insttrace");
  }
  if (ReadU16(bytes + 4) != RV_INSTTRACE_VERSION ||
      ReadU16(bytes + 6) != RV_INSTTRACE_HEADER_SIZE ||
      ReadU16(bytes + 8) != RV_INSTTRACE_RECORD_SIZE || bytes[10] != 32 ||
      bytes[11] != 4) {
    Fail("unsupported insttrace version/layout");
  }
  const std::uint32_t gpr_count = ReadU32(bytes + 12);
  if (gpr_count != 16 && gpr_count != 32) Fail("invalid insttrace GPR count");
}

bool TraceReader::Next(std::uint32_t *pc) {
  if (file_ == nullptr) Fail("insttrace is not open");
  unsigned char bytes[RV_INSTTRACE_RECORD_SIZE];
  const std::size_t size = std::fread(bytes, 1, sizeof(bytes), file_);
  if (std::ferror(file_) != 0) Fail("cannot read insttrace");
  if (size == 0) return false;
  if (size != sizeof(bytes)) Fail("truncated insttrace record");

  if (bytes[24] > RV_INSTTRACE_KIND_JALR || bytes[25] > 1) {
    Fail("invalid insttrace control-flow kind/taken");
  }
  *pc = ReadU32(bytes + 8);
  return true;
}

void TraceReader::Fail(const char *message) const {
  throw std::runtime_error(std::string(message) + ": " + path_ +
                           "; regenerate with INSTTRACE=1");
}
