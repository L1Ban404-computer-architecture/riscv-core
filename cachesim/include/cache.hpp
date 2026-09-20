#pragma once

#include <cstdint>
#include <string>
#include <vector>

/** @brief 与 RTL icache 同构的元数据 cache 配置。 */
enum class ReplacementPolicy {
  kFixed,
  kRoundRobin,
  kTreePlru,
};

struct CacheConfig {
  std::uint32_t block_bytes = 4;
  std::uint32_t sets = 16;
  std::uint32_t ways = 1;
  ReplacementPolicy policy = ReplacementPolicy::kRoundRobin;
};

struct CacheStats {
  std::uint64_t accesses = 0;
  std::uint64_t hits = 0;
  std::uint64_t misses = 0;
};

/** @brief 只维护 tag/valid 的 I-cache 功能模型，每个 PC 当作一次普通取指。 */
class Cache {
 public:
  explicit Cache(const CacheConfig &config);

  /** @brief 访问 addr 对应的块；命中返回 true。 */
  bool Access(std::uint32_t addr);

  const CacheStats &stats() const { return stats_; }
  const CacheConfig &config() const { return config_; }

 private:
  std::uint32_t SetIndex(std::uint32_t addr) const;
  std::uint32_t Tag(std::uint32_t addr) const;
  std::uint32_t LineIndex(std::uint32_t set, std::uint32_t way) const;
  std::uint32_t SelectVictim(std::uint32_t set) const;
  std::uint32_t SelectPlruWay(std::uint32_t set) const;
  void UpdatePlru(std::uint32_t set, std::uint32_t way);
  void NoteFill(std::uint32_t set, std::uint32_t way);

  CacheConfig config_;
  std::uint32_t block_offset_w_ = 0;
  std::uint32_t set_index_bits_ = 0;
  std::uint32_t tree_levels_ = 0;
  std::vector<std::uint8_t> valid_;
  std::vector<std::uint32_t> tag_;
  std::vector<std::uint32_t> rr_next_;
  std::vector<std::uint32_t> plru_tree_;
  CacheStats stats_;
};

bool IsPowerOfTwo(std::uint32_t value);
unsigned FloorLog2(std::uint32_t value);
bool ParseReplacementPolicy(const char *text, ReplacementPolicy *out);
const char *ReplacementPolicyName(ReplacementPolicy policy);
std::string ValidateCacheConfig(const CacheConfig &config);
