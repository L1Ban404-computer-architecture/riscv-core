#pragma once

#include <cstdint>
#include <vector>

// 与 rtl/icache 同构的元数据模型。不存指令，只按 PC 更新 valid、tag 和替换状态。
// 地址布局是 { tag, set, block offset }，默认几何与 icache_pkg 相同。

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

class Cache {
 public:
  explicit Cache(const CacheConfig &config);

  // 访问 addr 所在的块。命中返回 true。
  bool Access(std::uint32_t addr);

  const CacheStats &stats() const { return stats_; }
  const CacheConfig &config() const { return config_; }

 private:
  std::uint32_t SetIndex(std::uint32_t addr) const;
  std::uint32_t Tag(std::uint32_t addr) const;
  std::uint32_t LineIndex(std::uint32_t set, std::uint32_t way) const;

  std::uint32_t SelectVictim(std::uint32_t set) const;
  void NoteFill(std::uint32_t set, std::uint32_t way);
  std::uint32_t SelectPlruWay(std::uint32_t set) const;
  void UpdatePlru(std::uint32_t set, std::uint32_t way);

  CacheConfig config_;
  std::uint32_t block_offset_w_ = 0;
  std::uint32_t set_index_bits_ = 0;
  std::uint32_t tree_levels_ = 0;

  // 下标是 set * ways + way。valid 为 0 时 tag 不可见。
  std::vector<std::uint8_t> valid_;
  std::vector<std::uint32_t> tag_;
  // 每组一份。rr_next_ 是下一次轮转候选；plru_tree_ 的每一位指向更久未用的子树。
  std::vector<std::uint32_t> rr_next_;
  std::vector<std::uint32_t> plru_tree_;
  CacheStats stats_;
};

// 命令行上的 fixed、rr、plru。
bool ParseReplacementPolicy(const char *text, ReplacementPolicy *out);
