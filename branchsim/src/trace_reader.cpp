#include "trace_reader.hpp"

namespace {

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

bool TraceReader::Next(TraceRecord *record) {
  insttrace::Record raw;
  if (!reader_.Next(&raw)) return false;
  const TraceRecord decoded = {raw.pc, raw.instr, raw.target, raw.kind, raw.taken};
  if (decoded.kind != DecodeKind(decoded.instr, reader_.GprCount())) {
    reader_.Fail("invalid insttrace control-flow kind/taken");
  }
  switch (decoded.kind) {
    case RV_INSTTRACE_KIND_NONE:
      if (decoded.target != 0 || decoded.taken) {
        reader_.Fail("invalid ordinary insttrace record");
      }
      break;
    case RV_INSTTRACE_KIND_BRANCH:
      if (decoded.target != decoded.pc + BranchOffset(decoded.instr)) {
        reader_.Fail("invalid insttrace branch target");
      }
      break;
    case RV_INSTTRACE_KIND_JAL:
      if (!decoded.taken ||
          decoded.target != decoded.pc + JalOffset(decoded.instr)) {
        reader_.Fail("invalid insttrace JAL target/taken");
      }
      break;
    case RV_INSTTRACE_KIND_JALR:
      if (!decoded.taken || decoded.target != raw.next_pc) {
        reader_.Fail("invalid insttrace JALR target/taken");
      }
      break;
  }
  *record = decoded;
  return true;
}
