#include "trace.hpp"

#include <cerrno>
#include <cstring>

PcTraceReader::~PcTraceReader() {
  if (file_ != nullptr) std::fclose(file_);
}

bool PcTraceReader::Open(const std::string &path) {
  if (file_ != nullptr) {
    std::fclose(file_);
    file_ = nullptr;
  }
  path_ = path;
  file_ = std::fopen(path.c_str(), "rb");
  return file_ != nullptr;
}

bool PcTraceReader::Next(std::uint32_t *pc, std::string *error) {
  if (error != nullptr) error->clear();
  if (file_ == nullptr || pc == nullptr) {
    if (error != nullptr) *error = "pctrace is not open";
    return false;
  }

  unsigned char bytes[4];
  const std::size_t n = std::fread(bytes, 1, sizeof(bytes), file_);
  if (n == 0) {
    if (std::ferror(file_) != 0) {
      if (error != nullptr) {
        *error = std::string("cannot read ") + path_ + ": " + std::strerror(errno);
      }
      return false;
    }
    return false;
  }
  if (n != sizeof(bytes)) {
    if (error != nullptr) {
      *error = path_ + " length is not a multiple of 4";
    }
    return false;
  }

  *pc = static_cast<std::uint32_t>(bytes[0]) |
        (static_cast<std::uint32_t>(bytes[1]) << 8) |
        (static_cast<std::uint32_t>(bytes[2]) << 16) |
        (static_cast<std::uint32_t>(bytes[3]) << 24);
  return true;
}
