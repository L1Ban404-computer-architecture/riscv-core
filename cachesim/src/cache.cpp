#include "cache.hpp"

#include <cstring>
#include <stdexcept>

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

bool ParseReplacementPolicy(const char *text, ReplacementPolicy *out) {
  if (text == nullptr || out == nullptr) return false;
  if (std::strcmp(text, "fixed") == 0) {
    *out = ReplacementPolicy::kFixed;
    return true;
  }
  if (std::strcmp(text, "rr") == 0) {
    *out = ReplacementPolicy::kRoundRobin;
    return true;
  }
  if (std::strcmp(text, "plru") == 0) {
    *out = ReplacementPolicy::kTreePlru;
    return true;
  }
  return false;
}

const char *ReplacementPolicyName(ReplacementPolicy policy) {
  switch (policy) {
    case ReplacementPolicy::kFixed:
      return "fixed";
    case ReplacementPolicy::kRoundRobin:
      return "rr";
    case ReplacementPolicy::kTreePlru:
      return "plru";
  }
  return "unknown";
}

std::string ValidateCacheConfig(const CacheConfig &config) {
  if (!IsPowerOfTwo(config.block_bytes)) {
    return "block-bytes must be a positive power of two";
  }
  if (config.block_bytes < 4) {
    return "block-bytes must be at least 4";
  }
  if (!IsPowerOfTwo(config.sets)) {
    return "sets must be a positive power of two";
  }
  if (!IsPowerOfTwo(config.ways)) {
    return "ways must be a positive power of two";
  }
  const unsigned block_offset_w = FloorLog2(config.block_bytes);
  const unsigned set_index_bits = config.sets > 1 ? FloorLog2(config.sets) : 0;
  if (block_offset_w + set_index_bits >= 32) {
    return "tag width must be positive";
  }
  return {};
}

Cache::Cache(const CacheConfig &config) : config_(config) {
  const std::string error = ValidateCacheConfig(config_);
  if (!error.empty()) throw std::invalid_argument(error);

  block_offset_w_ = FloorLog2(config_.block_bytes);
  set_index_bits_ = config_.sets > 1 ? FloorLog2(config_.sets) : 0;
  tree_levels_ = config_.ways > 1 ? FloorLog2(config_.ways) : 0;

  const std::size_t lines = static_cast<std::size_t>(config_.sets) * config_.ways;
  valid_.assign(lines, 0);
  tag_.assign(lines, 0);
  rr_next_.assign(config_.sets, 0);
  plru_tree_.assign(config_.sets, 0);
}

std::uint32_t Cache::SetIndex(std::uint32_t addr) const {
  if (config_.sets == 1) return 0;
  return (addr >> block_offset_w_) & (config_.sets - 1u);
}

std::uint32_t Cache::Tag(std::uint32_t addr) const {
  return addr >> (block_offset_w_ + set_index_bits_);
}

std::uint32_t Cache::LineIndex(std::uint32_t set, std::uint32_t way) const {
  return set * config_.ways + way;
}

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

void Cache::UpdatePlru(std::uint32_t set, std::uint32_t way) {
  std::uint32_t node = 0;
  std::uint32_t tree = plru_tree_[set];
  for (unsigned level = 0; level < tree_levels_; ++level) {
    const std::uint32_t direction =
        (way >> (tree_levels_ - 1u - level)) & 1u;
    tree &= ~(1u << node);
    tree |= ((direction ^ 1u) << node);
    node = node * 2u + 1u + direction;
  }
  plru_tree_[set] = tree;
}

std::uint32_t Cache::SelectVictim(std::uint32_t set) const {
  std::uint32_t full_victim = 0;
  if (config_.ways != 1) {
    switch (config_.policy) {
      case ReplacementPolicy::kFixed:
        full_victim = 0;
        break;
      case ReplacementPolicy::kRoundRobin:
        full_victim = rr_next_[set];
        break;
      case ReplacementPolicy::kTreePlru:
        full_victim = SelectPlruWay(set);
        break;
    }
  }

  for (std::uint32_t way = 0; way < config_.ways; ++way) {
    if (valid_[LineIndex(set, way)] == 0) return way;
  }
  return full_victim;
}

void Cache::NoteFill(std::uint32_t set, std::uint32_t way) {
  if (config_.ways == 1) return;
  if (config_.policy == ReplacementPolicy::kRoundRobin) {
    rr_next_[set] = (way == config_.ways - 1u) ? 0u : way + 1u;
  } else if (config_.policy == ReplacementPolicy::kTreePlru) {
    UpdatePlru(set, way);
  }
}

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
