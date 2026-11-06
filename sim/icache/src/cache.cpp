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
  const unsigned block_offset_bits = FloorLog2(config.block_bytes);
  const unsigned set_index_bits = FloorLog2(config.sets);
  if (block_offset_bits + set_index_bits >= 32) {
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

  block_offset_bits_ = FloorLog2(config_.block_bytes);
  set_index_bits_ = FloorLog2(config_.sets);
  tree_levels_ = FloorLog2(config_.ways);

  const std::size_t lines = static_cast<std::size_t>(config_.sets) * config_.ways;
  lines_.resize(lines);
  if (config_.policy == ReplacementPolicy::kRoundRobin) rr_next_.assign(config_.sets, 0);
  else if (config_.policy == ReplacementPolicy::kTreePlru) plru_tree_.assign(config_.sets, 0);
}

// 一次取指：先比 tag。命中时只有 PLRU 会把该路记成最近使用。
// 缺失则马上占住牺牲路，下一条 PC 就能看见这块，不等 RTL 里的回填拍数。
bool Cache::Access(std::uint32_t addr) {
  const std::uint32_t set = SetIndex(addr);
  const std::uint32_t tag = Tag(addr);
  std::uint32_t empty_way = config_.ways;

  ++stats_.accesses;
  for (std::uint32_t way = 0; way < config_.ways; ++way) {
    const auto &line = lines_[LineIndex(set, way)];
    if (line.valid && line.tag == tag) {
      ++stats_.hits;
      if (config_.policy == ReplacementPolicy::kTreePlru) UpdatePlru(set, way);
      return true;
    }
    if (!line.valid && empty_way == config_.ways) empty_way = way;
  }

  ++stats_.misses;
  // 查询时已记住首个空路，满组才需要替换策略；单路自然选择第 0 路。
  std::uint32_t victim = empty_way;
  if (victim == config_.ways) {
    victim = config_.policy == ReplacementPolicy::kRoundRobin ? rr_next_[set] : SelectPlruWay(set);
  }
  lines_[LineIndex(set, victim)] = {true, tag};
  // 轮转只在填入时推进；PLRU 把填入也记成一次访问。
  if (config_.policy == ReplacementPolicy::kRoundRobin) {
    rr_next_[set] = (victim == config_.ways - 1u) ? 0u : victim + 1u;
  } else {
    UpdatePlru(set, victim);
  }
  return false;
}

// 块内偏移不参与比较。同一块里的连续 PC 共用一个 tag。
std::uint32_t Cache::SetIndex(std::uint32_t addr) const {
  return (addr >> block_offset_bits_) & (config_.sets - 1u);
}

std::uint32_t Cache::Tag(std::uint32_t addr) const {
  return addr >> (block_offset_bits_ + set_index_bits_);
}

std::size_t Cache::LineIndex(std::uint32_t set, std::uint32_t way) const {
  return static_cast<std::size_t>(set) * config_.ways + way;
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
