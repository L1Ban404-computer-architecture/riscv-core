#include "trace_reader.hpp"

#include <cstring>
#include <stdexcept>

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

std::uint32_t SignExtend(std::uint32_t value, unsigned bits) {
  const std::uint32_t sign = 1u << (bits - 1);
  return (value ^ sign) - sign;
}

std::uint32_t BranchOffset(std::uint32_t instr) {
  const std::uint32_t imm = ((instr >> 31) << 12) |
                          (((instr >> 7) & 1u) << 11) |
                          (((instr >> 25) & 0x3fu) << 5) |
                          (((instr >> 8) & 0xfu) << 1);
  return SignExtend(imm, 13);
}

std::uint32_t JalOffset(std::uint32_t instr) {
  const std::uint32_t imm = ((instr >> 31) << 20) |
                          (((instr >> 12) & 0xffu) << 12) |
                          (((instr >> 20) & 1u) << 11) |
                          (((instr >> 21) & 0x3ffu) << 1);
  return SignExtend(imm, 21);
}

std::uint8_t DecodeKind(std::uint32_t instr, std::uint32_t gpr_count) {
  const std::uint32_t opcode = instr & 0x7fu;
  const std::uint32_t funct3 = (instr >> 12) & 7u;
  const std::uint32_t rd = (instr >> 7) & 31u;
  const std::uint32_t rs1 = (instr >> 15) & 31u;
  const std::uint32_t rs2 = (instr >> 20) & 31u;
  if (opcode == 0x63u && funct3 != 2 && funct3 != 3 &&
      rs1 < gpr_count && rs2 < gpr_count) {
    return RV_INSTTRACE_KIND_BRANCH;
  }
  if (opcode == 0x6fu && rd < gpr_count) {
    return RV_INSTTRACE_KIND_JAL;
  }
  if (opcode == 0x67u && funct3 == 0 && rd < gpr_count && rs1 < gpr_count) {
    return RV_INSTTRACE_KIND_JALR;
  }
  return RV_INSTTRACE_KIND_NONE;
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
  gpr_count_ = ReadU32(bytes + 12);
  if (gpr_count_ != 16 && gpr_count_ != 32) {
    Fail("invalid insttrace GPR count");
  }
}

bool TraceReader::Next(TraceRecord *record) {
  if (file_ == nullptr) Fail("insttrace is not open");
  unsigned char bytes[RV_INSTTRACE_RECORD_SIZE];
  const std::size_t n = std::fread(bytes, 1, sizeof(bytes), file_);
  if (std::ferror(file_) != 0) Fail("cannot read insttrace");
  if (n == 0) return false;
  if (n != sizeof(bytes)) Fail("truncated insttrace record");

  TraceRecord decoded;
  decoded.pc = ReadU32(bytes + 8);
  decoded.instr = ReadU32(bytes + 12);
  decoded.target = ReadU32(bytes + 20);
  decoded.kind = bytes[24];
  decoded.taken = bytes[25] != 0;
  const std::uint32_t next_pc = ReadU32(bytes + 16);
  if (bytes[25] > 1 || decoded.kind != DecodeKind(decoded.instr, gpr_count_)) {
    Fail("invalid insttrace control-flow kind/taken");
  }
  switch (decoded.kind) {
    case RV_INSTTRACE_KIND_NONE:
      if (decoded.target != 0 || decoded.taken) {
        Fail("invalid ordinary insttrace record");
      }
      break;
    case RV_INSTTRACE_KIND_BRANCH:
      if (decoded.target != decoded.pc + BranchOffset(decoded.instr)) {
        Fail("invalid insttrace branch target");
      }
      break;
    case RV_INSTTRACE_KIND_JAL:
      if (!decoded.taken ||
          decoded.target != decoded.pc + JalOffset(decoded.instr)) {
        Fail("invalid insttrace JAL target/taken");
      }
      break;
    case RV_INSTTRACE_KIND_JALR:
      if (!decoded.taken || decoded.target != next_pc) {
        Fail("invalid insttrace JALR target/taken");
      }
      break;
  }
  *record = decoded;
  return true;
}

[[noreturn]] void TraceReader::Fail(const char *message) const {
  throw std::runtime_error(std::string(message) + ": " + path_ +
                           "; regenerate with INSTTRACE=1");
}
