#include "ras.hpp"

#include <stdexcept>

namespace {
bool IsLink(std::uint32_t reg) { return reg == 1 || reg == 5; }
std::uint32_t Mask(std::uint32_t bits) {
  return bits == 32 ? 0xffffffffu : (std::uint32_t{1} << bits) - 1;
}
std::uint32_t Bits(std::uint32_t value) {
  std::uint32_t bits = 0;
  while (value) { ++bits; value >>= 1; }
  return bits;
}
}  // namespace

RasAction DecodeRasAction(std::uint32_t instr) {
  const auto rd = (instr >> 7) & 31u;
  const auto rs1 = (instr >> 15) & 31u;
  if (IsJal(instr)) return {false, IsLink(rd)};
  if (IsJalr(instr)) return {IsLink(rs1) && (!IsLink(rd) || rd != rs1), IsLink(rd)};
  return {};
}

bool IsRasReturn(std::uint32_t instr) {
  // 非零立即数仍遵循 push/pop 提示，但不分配 return 类型：栈顶并非其目标。
  return DecodeRasAction(instr).pop && (instr >> 20) == 0;
}

Ras::Ras(std::uint32_t entries, std::uint32_t target_bits) : target_bits_(target_bits) {
  if (entries > 64 || (entries && (entries & (entries - 1))))
    throw std::invalid_argument("ras-entries must be zero or a power of two <= 64");
  if (target_bits < 2 || target_bits > 32)
    throw std::invalid_argument("ras-target-bits must be in [2, 32]");
  entries_.resize(entries);
}

std::uint32_t Ras::Top(std::uint32_t pc) const {
  if (Empty()) throw std::logic_error("empty RAS has no target");
  return (pc & ~Mask(target_bits_)) |
         entries_[(next_ + entries_.size() - 1) % entries_.size()];
}

void Ras::Update(const BranchInput &input) {
  if (!Enabled()) return;
  const auto action = DecodeRasAction(input.instr);
  // 先 pop 再 push，协程交换时不会错误溢出，也不会用新栈顶预测自身。
  if (action.pop) {
    if (Empty()) ++underflows;
    else {
      next_ = (next_ + entries_.size() - 1) % entries_.size();
      --count_;
    }
  }
  if (action.push) {
    entries_[next_] = (input.pc + 4u) & Mask(target_bits_);
    next_ = (next_ + 1) % entries_.size();
    if (count_ == entries_.size()) ++overflows;
    else ++count_;
  }
}

void Ras::Clear() { next_ = count_ = 0; }

std::uint64_t Ras::StorageBits() const {
  if (!Enabled()) return 0;
  // RV32E/I、IALIGN=32：PC+4 低两位不存。环形写指针 + 有效项计数。
  return entries_.size() * (target_bits_ - 2) + Bits(entries_.size() - 1) + Bits(entries_.size());
}

ReturnTable::ReturnTable(std::uint32_t entries, std::uint32_t pc_bits) : pc_bits_(pc_bits) {
  if (entries > 64 || (entries && (entries & (entries - 1))))
    throw std::invalid_argument("ras-filter-entries must be zero or a power of two <= 64");
  if (pc_bits < 1 || pc_bits > 30)
    throw std::invalid_argument("return tag bits must be in [1, 30]");
  entries_.resize(entries);
}

bool ReturnTable::Lookup(std::uint32_t pc) const {
  for (const auto &entry : entries_)
    if (entry.valid && entry.tag == ((pc >> 2) & Mask(pc_bits_))) return true;
  return false;
}

void ReturnTable::Update(std::uint32_t pc) {
  if (entries_.empty() || Lookup(pc)) return;
  entries_[next_] = {true, (pc >> 2) & Mask(pc_bits_)};
  next_ = (next_ + 1) % entries_.size();
}

std::uint64_t ReturnTable::StorageBits() const {
  return entries_.empty() ? 0 : entries_.size() * (pc_bits_ + 1) + Bits(entries_.size() - 1);
}
