#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

#include "cache.hpp"
#include "trace.hpp"

namespace {

const char *ReadArgs(int argc, char **argv, CacheConfig *config);
Cache MakeCache(const CacheConfig &config);
void PrintStats(const CacheStats &stats);

}  // namespace

// 读几何和轨迹，逐条 PC 访问，最后打印命中率。
int main(int argc, char **argv) {
  CacheConfig config;
  const char *trace_path = ReadArgs(argc, argv, &config);

  Cache cache = MakeCache(config);
  PcTraceReader reader;
  reader.Open(trace_path);

  std::uint32_t pc = 0;
  while (reader.Next(&pc)) cache.Access(pc);

  PrintStats(cache.stats());
  return 0;
}

namespace {

bool Flag(const char *arg, const char *name) {
  const std::size_t n = std::strlen(name);
  return std::strncmp(arg, name, n) == 0 && (arg[n] == '\0' || arg[n] == '=');
}

const char *FlagValue(int argc, char **argv, int *i) {
  const char *eq = std::strchr(argv[*i], '=');
  if (eq != nullptr) return eq + 1;
  if (*i + 1 >= argc) {
    std::fprintf(stderr, "missing value for %s\n", argv[*i]);
    std::exit(2);
  }
  return argv[++*i];
}

std::uint32_t Number(const char *text) {
  return static_cast<std::uint32_t>(std::strtoul(text, nullptr, 0));
}

// 未写明的几何留在 CacheConfig 的默认值上。两种写法都接受：--sets 16 与 --sets=16。
const char *ReadArgs(int argc, char **argv, CacheConfig *config) {
  const char *trace_path = nullptr;
  for (int i = 1; i < argc; ++i) {
    const char *arg = argv[i];
    if (std::strcmp(arg, "-h") == 0 || std::strcmp(arg, "--help") == 0) {
      std::printf(
          "Usage: %s --trace PATH [--block-bytes N] [--sets N] [--ways N] "
          "[--policy fixed|rr|plru]\n",
          argv[0]);
      std::exit(0);
    }
    if (Flag(arg, "--trace")) {
      trace_path = FlagValue(argc, argv, &i);
    } else if (Flag(arg, "--block-bytes")) {
      config->block_bytes = Number(FlagValue(argc, argv, &i));
    } else if (Flag(arg, "--sets")) {
      config->sets = Number(FlagValue(argc, argv, &i));
    } else if (Flag(arg, "--ways")) {
      config->ways = Number(FlagValue(argc, argv, &i));
    } else if (Flag(arg, "--policy")) {
      if (!ParseReplacementPolicy(FlagValue(argc, argv, &i), &config->policy)) {
        std::fprintf(stderr, "policy must be fixed, rr, or plru\n");
        std::exit(2);
      }
    } else {
      std::fprintf(stderr, "unknown argument: %s\n", arg);
      std::exit(2);
    }
  }

  if (trace_path == nullptr) {
    std::fprintf(stderr, "missing --trace\n");
    std::exit(2);
  }
  return trace_path;
}

Cache MakeCache(const CacheConfig &config) {
  try {
    return Cache(config);
  } catch (const std::invalid_argument &err) {
    std::fprintf(stderr, "%s\n", err.what());
    std::exit(2);
  }
}

void PrintStats(const CacheStats &stats) {
  if (stats.accesses == 0) {
    std::printf("accesses=0 hits=0 misses=0 hit_rate=-\n");
    return;
  }
  const double hit_rate =
      static_cast<double>(stats.hits) / static_cast<double>(stats.accesses);
  std::printf("accesses=%" PRIu64 " hits=%" PRIu64 " misses=%" PRIu64
              " hit_rate=%.6f\n",
              stats.accesses, stats.hits, stats.misses, hit_rate);
}

}  // namespace
