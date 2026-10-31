#include "insttrace_reader.hpp"

#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <sys/file.h>
#include <unistd.h>

#include "process.hpp"

namespace insttrace {

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

void EnsureTrace(const std::filesystem::path &path) {
  namespace fs = std::filesystem;
  const auto target = fs::absolute(path);
  if (fs::exists(target)) return;
  fs::create_directories(target.parent_path());

  struct Lock {
    int fd;
    ~Lock() { if (fd >= 0) close(fd); }
  } lock{open((target.string() + ".lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0666)};
  if (lock.fd < 0 || flock(lock.fd, LOCK_EX) != 0)
    throw std::runtime_error("cannot lock trace: " + target.string());
  if (fs::exists(target)) return;

  const auto workspace = sim::CoreDirectory().parent_path();
  const auto capture = fs::path(target.string() + ".capture");
  const auto generated = capture / "runner-insttrace.bin";
  fs::create_directories(capture);
  fs::remove(generated);
  sim::RunCommand({"make", "-C", (workspace / "am-kernels/benchmarks/microbench").string(),
                   "ARCH=runner", "DUT=nemu", "REF=", "mainargs=train", "INSTTRACE=1",
                   "AM_HOME=" + (workspace / "abstract-machine").string(),
                   "YSYX_HOME=" + workspace.string(), "LOG_DIR=" + capture.string(), "run"},
                  capture / "make.log");
  if (!fs::is_regular_file(generated))
    throw std::runtime_error("microbench did not produce a trace; see " + (capture / "make.log").string());
  Reader verifier;
  verifier.Open(generated.c_str());
  const auto size = fs::file_size(generated);
  if (size <= RV_INSTTRACE_HEADER_SIZE ||
      (size - RV_INSTTRACE_HEADER_SIZE) % RV_INSTTRACE_RECORD_SIZE != 0)
    throw std::runtime_error("incomplete microbench train trace: " + generated.string());
  fs::rename(generated, target);
}

Reader::~Reader() {
  if (file_ != nullptr) std::fclose(file_);
}

void Reader::Open(const char *path) {
  EnsureTrace(path);
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
  gpr_count_ = ReadU32(bytes + 12);
  if (gpr_count_ != 16 && gpr_count_ != 32) Fail("invalid insttrace GPR count");
}

bool Reader::Next(Record *record) {
  if (file_ == nullptr) Fail("insttrace is not open");
  unsigned char bytes[RV_INSTTRACE_RECORD_SIZE];
  const std::size_t size = std::fread(bytes, 1, sizeof(bytes), file_);
  if (std::ferror(file_) != 0) Fail("cannot read insttrace");
  if (size == 0) return false;
  if (size != sizeof(bytes)) Fail("truncated insttrace record");

  if (bytes[24] > RV_INSTTRACE_KIND_JALR || bytes[25] > 1) {
    Fail("invalid insttrace control-flow kind/taken");
  }
  record->pc = ReadU32(bytes + 8);
  record->instr = ReadU32(bytes + 12);
  record->next_pc = ReadU32(bytes + 16);
  record->target = ReadU32(bytes + 20);
  record->kind = bytes[24];
  record->taken = bytes[25] != 0;
  return true;
}

[[noreturn]] void Reader::Fail(const char *message) const {
  throw std::runtime_error(std::string(message) + ": " + path_ +
                           "; regenerate with INSTTRACE=1");
}

}  // namespace insttrace
