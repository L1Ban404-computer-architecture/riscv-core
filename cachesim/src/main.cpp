#include <cerrno>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <getopt.h>
#include <string>

#include "cache.hpp"
#include "trace.hpp"

namespace {

enum LongOption {
  kOptBlockBytes = 256,
  kOptSets,
  kOptWays,
  kOptPolicy,
  kOptTrace,
};

void PrintUsage(const char *prog) {
  std::printf(
      "Usage: %s --trace PATH [OPTION...]\n\n"
      "Replay a little-endian uint32 PC stream against an I-cache metadata model.\n\n"
      "Options:\n"
      "  --trace=PATH           binary PC trace from runner --pctrace\n"
      "  --block-bytes=N        line size, power of two, default 4\n"
      "  --sets=N               set count, power of two, default 16\n"
      "  --ways=N               way count, power of two, default 1\n"
      "  --policy=fixed|rr|plru replacement policy, default rr\n"
      "  -h, --help             show this help\n",
      prog);
}

bool ParseU32(const char *text, std::uint32_t *out) {
  if (text == nullptr || text[0] == '-' || out == nullptr) return false;
  errno = 0;
  char *end = nullptr;
  const unsigned long value = std::strtoul(text, &end, 0);
  if (errno != 0 || end == text || *end != '\0' || value > UINT32_MAX) {
    return false;
  }
  *out = static_cast<std::uint32_t>(value);
  return true;
}

}  // namespace

int main(int argc, char **argv) {
  static const option long_options[] = {
      {"block-bytes", required_argument, nullptr, kOptBlockBytes},
      {"sets", required_argument, nullptr, kOptSets},
      {"ways", required_argument, nullptr, kOptWays},
      {"policy", required_argument, nullptr, kOptPolicy},
      {"trace", required_argument, nullptr, kOptTrace},
      {"help", no_argument, nullptr, 'h'},
      {nullptr, 0, nullptr, 0},
  };

  CacheConfig config;
  std::string trace_path;
  optind = 1;
  while (true) {
    const int opt = getopt_long(argc, argv, "h", long_options, nullptr);
    if (opt == -1) break;
    switch (opt) {
      case kOptBlockBytes:
        if (!ParseU32(optarg, &config.block_bytes)) {
          std::fprintf(stderr, "invalid --block-bytes: %s\n", optarg);
          return 2;
        }
        break;
      case kOptSets:
        if (!ParseU32(optarg, &config.sets)) {
          std::fprintf(stderr, "invalid --sets: %s\n", optarg);
          return 2;
        }
        break;
      case kOptWays:
        if (!ParseU32(optarg, &config.ways)) {
          std::fprintf(stderr, "invalid --ways: %s\n", optarg);
          return 2;
        }
        break;
      case kOptPolicy:
        if (!ParseReplacementPolicy(optarg, &config.policy)) {
          std::fprintf(stderr, "invalid --policy: %s\n", optarg);
          return 2;
        }
        break;
      case kOptTrace:
        trace_path = optarg;
        break;
      case 'h':
        PrintUsage(argv[0]);
        return 0;
      default:
        PrintUsage(argv[0]);
        return 2;
    }
  }

  if (optind < argc) {
    std::fprintf(stderr, "unexpected positional argument: %s\n", argv[optind]);
    return 2;
  }
  if (trace_path.empty()) {
    std::fprintf(stderr, "missing required option --trace\n");
    PrintUsage(argv[0]);
    return 2;
  }

  const std::string config_error = ValidateCacheConfig(config);
  if (!config_error.empty()) {
    std::fprintf(stderr, "%s\n", config_error.c_str());
    return 2;
  }

  PcTraceReader reader;
  if (!reader.Open(trace_path)) {
    std::fprintf(stderr, "cannot open trace %s\n", trace_path.c_str());
    return 1;
  }

  Cache cache(config);
  std::uint32_t pc = 0;
  std::string read_error;
  while (reader.Next(&pc, &read_error)) cache.Access(pc);
  if (!read_error.empty()) {
    std::fprintf(stderr, "%s\n", read_error.c_str());
    return 1;
  }

  const CacheStats &stats = cache.stats();
  if (stats.accesses == 0) {
    std::printf("accesses=0 hits=0 misses=0 hit_rate=-\n");
  } else {
    const double hit_rate =
        static_cast<double>(stats.hits) / static_cast<double>(stats.accesses);
    std::printf("accesses=%" PRIu64 " hits=%" PRIu64 " misses=%" PRIu64
                " hit_rate=%.6f\n",
                stats.accesses, stats.hits, stats.misses, hit_rate);
  }
  return 0;
}
