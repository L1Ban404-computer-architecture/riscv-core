#include "cache.hpp"

#include <stdexcept>
#include <string>

namespace {

bool IsPowerOfTwo(std::uint32_t value) {
  return value > 0 && (value & (value - 1u)) == 0;
}

unsigned FloorLog2(std::uint32_t value) {
  unsigned bits = 0;
  while (value > 1u) {
    value >>= 1;
    ++bits;
  }
  return bits;
}

// 组索引和块偏移都用掩码取出，所以组数、路数、块大小必须是 2 的幂，且 tag 至少留 1 位。
void ValidateCacheConfig(const CacheConfig &config) {
  if (!IsPowerOfTwo(config.block_bytes)) {
    throw std::invalid_argument("block-bytes must be a positive power of two");
  }
  if (config.block_bytes < 4) {
    throw std::invalid_argument("block-bytes must be at least 4");
  }
  if (!IsPowerOfTwo(config.sets)) {
    throw std::invalid_argument("sets must be a positive power of two");
  }
  if (!IsPowerOfTwo(config.ways)) {
    throw std::invalid_argument("ways must be a positive power of two");
  }
  // 一组 PLRU 有 ways-1 个节点，状态保存在一个 32 位整数中。
  if (config.policy == ReplacementPolicy::kTreePlru && config.ways > 32) {
    throw std::invalid_argument("plru supports at most 32 ways");
  }
  const unsigned block_offset_w = FloorLog2(config.block_bytes);
  const unsigned set_index_bits = FloorLog2(config.sets);
  if (block_offset_w + set_index_bits >= 32) {
    throw std::invalid_argument("tag width must be positive");
  }
}

}  // namespace

ReplacementPolicy ParseReplacementPolicy(const std::string &text) {
  if (text == "rr") return ReplacementPolicy::kRoundRobin;
  if (text == "plru") return ReplacementPolicy::kTreePlru;
  throw std::invalid_argument("policy must be rr or plru");
}

Cache::Cache(const CacheConfig &config) : config_(config) {
  ValidateCacheConfig(config_);

  block_offset_w_ = FloorLog2(config_.block_bytes);
  set_index_bits_ = FloorLog2(config_.sets);
  tree_levels_ = FloorLog2(config_.ways);

  const std::size_t lines = static_cast<std::size_t>(config_.sets) * config_.ways;
  valid_.assign(lines, 0);
  tag_.assign(lines, 0);
  if (config_.policy == ReplacementPolicy::kRoundRobin) rr_next_.assign(config_.sets, 0);
  else if (config_.policy == ReplacementPolicy::kTreePlru) plru_tree_.assign(config_.sets, 0);
}

// 一次取指：先比 tag。命中时只有 PLRU 会把该路记成最近使用。
// 缺失则马上占住牺牲路，下一条 PC 就能看见这块，不等 RTL 里的回填拍数。
bool Cache::Access(std::uint32_t addr) {
  const std::uint32_t set = SetIndex(addr);
  const std::uint32_t tag = Tag(addr);

  ++stats_.accesses;
  for (std::uint32_t way = 0; way < config_.ways; ++way) {
    const std::uint32_t index = LineIndex(set, way);
    if (valid_[index] != 0 && tag_[index] == tag) {
      ++stats_.hits;
      if (config_.ways > 1 && config_.policy == ReplacementPolicy::kTreePlru) {
        UpdatePlru(set, way);
      }
      return true;
    }
  }

  ++stats_.misses;
  const std::uint32_t victim = SelectVictim(set);
  const std::uint32_t index = LineIndex(set, victim);
  valid_[index] = 1;
  tag_[index] = tag;
  NoteFill(set, victim);
  return false;
}

// 块内偏移不参与比较。同一块里的连续 PC 共用一个 tag。
std::uint32_t Cache::SetIndex(std::uint32_t addr) const {
  return (addr >> block_offset_w_) & (config_.sets - 1u);
}

std::uint32_t Cache::Tag(std::uint32_t addr) const {
  return addr >> (block_offset_w_ + set_index_bits_);
}

std::uint32_t Cache::LineIndex(std::uint32_t set, std::uint32_t way) const {
  return set * config_.ways + way;
}

// 还有空路时用编号最小的无效路，组满时使用轮转或 Tree-PLRU。
// 一路时没有替换状态，满组牺牲路保持 0。
std::uint32_t Cache::SelectVictim(std::uint32_t set) const {
  for (std::uint32_t way = 0; way < config_.ways; ++way) {
    if (valid_[LineIndex(set, way)] == 0) return way;
  }
  if (config_.ways == 1) return 0;

  switch (config_.policy) {
    case ReplacementPolicy::kRoundRobin: return rr_next_[set];
    case ReplacementPolicy::kTreePlru: return SelectPlruWay(set);
  }
  return 0;
}

// 轮转从实际占用的那一路推进，命中不改它。PLRU 把这次填入也记成一次访问。
void Cache::NoteFill(std::uint32_t set, std::uint32_t way) {
  if (config_.ways == 1) return;
  if (config_.policy == ReplacementPolicy::kRoundRobin) {
    rr_next_[set] = (way == config_.ways - 1u) ? 0u : way + 1u;
  } else if (config_.policy == ReplacementPolicy::kTreePlru) {
    UpdatePlru(set, way);
  }
}

// 从根沿“更久未用”下降。每一层的 0/1 拼进牺牲路编号。
std::uint32_t Cache::SelectPlruWay(std::uint32_t set) const {
  std::uint32_t node = 0;
  std::uint32_t way = 0;
  const std::uint32_t tree = plru_tree_[set];
  for (unsigned level = 0; level < tree_levels_; ++level) {
    const std::uint32_t direction = (tree >> node) & 1u;
    way = (way << 1) | direction;
    node = node * 2u + 1u + direction;
  }
  return way;
}

// 沿被访问路向下，把每一层的位拨到另一侧，使它指向剩下更久未用的子树。
void Cache::UpdatePlru(std::uint32_t set, std::uint32_t way) {
  std::uint32_t node = 0;
  std::uint32_t tree = plru_tree_[set];
  for (unsigned level = 0; level < tree_levels_; ++level) {
    const std::uint32_t direction = (way >> (tree_levels_ - 1u - level)) & 1u;
    tree &= ~(1u << node);
    tree |= (direction ^ 1u) << node;
    node = node * 2u + 1u + direction;
  }
  plru_tree_[set] = tree;
}
