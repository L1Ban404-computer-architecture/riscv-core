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
  if (config.jal_btb && config.jal_btb_entries == 0) {
    throw std::invalid_argument("jal-btb-entries must be positive when jal-btb is enabled");
  }
  if (config.method == "none") return;
  table_ = MakeTable(config.sets, config.ways);
  if (config.jal_btb) jal_table_ = MakeTable(1, config.jal_btb_entries);
}

Btb::Table Btb::MakeTable(std::uint32_t sets, std::uint32_t ways) const {
  Table table;
  table.sets = sets;
  table.ways = ways;
  if (ways > table.entries.max_size() / sets) {
    throw std::invalid_argument("BTB geometry is too large");
  }
  table.entries.resize(static_cast<std::size_t>(sets) * ways);
  if (config_.policy == "rr") table.rr_next.resize(sets, 0);
  return table;
}

BtbPrediction Btb::Lookup(std::uint32_t pc) const {
  if (config_.method == "none") return {};
  // 两张表都只按 PC 查询；标签截断导致同时命中时，JAL 表优先。
  if (config_.jal_btb) {
    const auto jal = LookupTable(pc, jal_table_);
    if (jal.hit) return jal;
  }
  return LookupTable(pc, table_);
}

BtbPrediction Btb::LookupTable(std::uint32_t pc, const Table &table) const {
  const std::size_t begin = SetBegin(pc, table);
  for (std::uint32_t way = 0; way < table.ways; ++way) {
    const Entry &entry = table.entries[begin + way];
    if (entry.valid && entry.pc == Tag(pc)) {
      const std::uint32_t target = (pc & ~LowMask(config_.target_bits)) | entry.target;
      return {true, target, entry.type, entry.backward};
    }
  }
  return {};
}

void Btb::Update(std::uint32_t pc, std::uint32_t target, BtbType type) {
  if (config_.method == "none") return;
  Table &table = config_.jal_btb && type == BtbType::kJal ? jal_table_ : table_;
  const std::size_t begin = SetBegin(pc, table);
  const std::uint32_t set = (pc >> 2) & (table.sets - 1u);
  std::uint32_t selected = table.ways;
  // 先找已有项；未命中时优先选编号最小的空路。
  for (std::uint32_t way = 0; way < table.ways; ++way) {
    const Entry &entry = table.entries[begin + way];
    if (entry.valid && entry.pc == Tag(pc)) {
      selected = way;
      break;
    }
  }
  const bool hit = selected != table.ways;
  if (!hit) {
    for (std::uint32_t way = 0; way < table.ways; ++way) {
      if (!table.entries[begin + way].valid) {
        selected = way;
        break;
      }
    }
  }
  if (selected == table.ways) {
    if (config_.policy == "rr") selected = table.rr_next[set];
    else {
      selected = 0;
      for (std::uint32_t way = 1; way < table.ways; ++way) {
        if (table.entries[begin + way].age > table.entries[begin + selected].age) {
          selected = way;
        }
      }
    }
  }

  Entry &entry = table.entries[begin + selected];
  if (config_.policy == "lru") {
    // age 是组内名次，0 表示最新。名次有界，不依赖会溢出的时间戳。
    const std::uint32_t old_age = hit ? entry.age : table.ways;
    for (std::uint32_t way = 0; way < table.ways; ++way) {
      Entry &other = table.entries[begin + way];
      if (other.valid && other.age < old_age) ++other.age;
    }
  } else if (!hit) {
    table.rr_next[set] = (selected + 1u) % table.ways;
  }
  const bool backward = ((target - pc) & 0x80000000u) != 0;
  entry = {true, Tag(pc), target & LowMask(config_.target_bits), type, 0, backward};
}

std::size_t Btb::SetBegin(std::uint32_t pc, const Table &table) const {
  return static_cast<std::size_t>((pc >> 2) & (table.sets - 1u)) * table.ways;
}

std::uint32_t Btb::Tag(std::uint32_t pc) const {
  // PC[1:0] 是固定的 4 字节指令对齐位，不写入标签。
  return (pc >> 2) & LowMask(config_.pc_bits);
}
