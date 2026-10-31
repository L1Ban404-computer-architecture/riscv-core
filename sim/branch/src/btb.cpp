#include "btb.hpp"

#include <stdexcept>

namespace {

std::uint32_t LowMask(std::uint32_t bits) {
  return bits == 32 ? 0xffffffffu : (std::uint32_t{1} << bits) - 1u;
}

}  // namespace

Btb::Btb(const BtbConfig &config) : config_(config) {
  if (config.method != "none" && config.method != "table") {
    throw std::invalid_argument("btb must be none or table");
  }
  if (config.sets == 0 || (config.sets & (config.sets - 1u)) != 0) {
    throw std::invalid_argument("btb-sets must be a positive power of two");
  }
  if (config.ways == 0) {
    throw std::invalid_argument("btb-ways must be positive");
  }
  if (config.policy != "rr" && config.policy != "lru") {
    throw std::invalid_argument("btb-policy must be rr or lru");
  }
  if (config.pc_bits < 1 || config.pc_bits > 30) {
    throw std::invalid_argument("pc-bits must be in [1, 30]");
  }
  if (config.target_bits < 2 || config.target_bits > 32) {
    throw std::invalid_argument("target-bits must be in [2, 32]");
  }
  if (config.method == "none") return;
  if (config.ways > entries_.max_size() / config.sets) {
    throw std::invalid_argument("BTB geometry is too large");
  }
  entries_.resize(static_cast<std::size_t>(config.sets) * config.ways);
  if (config.policy == "rr") rr_next_.resize(config.sets, 0);
}

BtbPrediction Btb::Lookup(std::uint32_t pc) const {
  if (config_.method == "none") return {};
  const std::size_t begin = SetBegin(pc);
  for (std::uint32_t way = 0; way < config_.ways; ++way) {
    const Entry &entry = entries_[begin + way];
    if (entry.valid && entry.pc == Tag(pc)) {
      const std::uint32_t target = (pc & ~LowMask(config_.target_bits)) | entry.target;
      return {true, target, entry.type, entry.backward};
    }
  }
  return {};
}

void Btb::Update(std::uint32_t pc, std::uint32_t target, BtbType type) {
  if (config_.method == "none") return;
  const std::size_t begin = SetBegin(pc);
  const std::uint32_t set = (pc >> 2) & (config_.sets - 1u);
  std::uint32_t selected = config_.ways;
  // 先找已有项；未命中时优先选编号最小的空路。
  for (std::uint32_t way = 0; way < config_.ways; ++way) {
    const Entry &entry = entries_[begin + way];
    if (entry.valid && entry.pc == Tag(pc)) {
      selected = way;
      break;
    }
  }
  const bool hit = selected != config_.ways;
  if (!hit) {
    for (std::uint32_t way = 0; way < config_.ways; ++way) {
      if (!entries_[begin + way].valid) {
        selected = way;
        break;
      }
    }
  }
  if (selected == config_.ways) {
    if (config_.policy == "rr") selected = rr_next_[set];
    else {
      selected = 0;
      for (std::uint32_t way = 1; way < config_.ways; ++way) {
        if (entries_[begin + way].age > entries_[begin + selected].age) {
          selected = way;
        }
      }
    }
  }

  Entry &entry = entries_[begin + selected];
  if (config_.policy == "lru") {
    // age 是组内名次，0 表示最新。名次有界，不依赖会溢出的时间戳。
    const std::uint32_t old_age = hit ? entry.age : config_.ways;
    for (std::uint32_t way = 0; way < config_.ways; ++way) {
      Entry &other = entries_[begin + way];
      if (other.valid && other.age < old_age) ++other.age;
    }
  } else if (!hit) {
    rr_next_[set] = (selected + 1u) % config_.ways;
  }
  const bool backward = ((target - pc) & 0x80000000u) != 0;
  entry = {true, Tag(pc), target & LowMask(config_.target_bits), type, 0, backward};
}

std::size_t Btb::SetBegin(std::uint32_t pc) const {
  return static_cast<std::size_t>((pc >> 2) & (config_.sets - 1u)) * config_.ways;
}

std::uint32_t Btb::Tag(std::uint32_t pc) const {
  // PC[1:0] 是固定的 4 字节指令对齐位，不写入标签。
  return (pc >> 2) & LowMask(config_.pc_bits);
}
