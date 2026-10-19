#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>

#include "predictor.hpp"
#include "trace.hpp"

namespace {

struct Options {
  std::string trace;
  std::string bht = "btfn";
  BtbConfig btb;
  RasConfig ras;
};

void Usage(const char *prog) {
  std::printf(
      "Usage: %s --trace PATH [options]\n"
      "  --bht not-taken|btfn      default btfn\n"
      "  --btb none|table          default table\n"
      "  --btb-sets N              default 64 (positive power of two)\n"
      "  --btb-ways N              default 2\n"
      "  --btb-policy rr|lru       default rr\n"
      "  --ras none|stack          default stack\n"
      "  --ras-depth N             default 16\n", prog);
}

std::uint32_t Number(const std::string &text) {
  if (text.empty() || text[0] == '-' || text.find_first_of(" \t\r\n") != std::string::npos) {
    throw std::invalid_argument("invalid unsigned integer: " + text);
  }
  errno = 0;
  char *end = nullptr;
  const unsigned long long number = std::strtoull(text.c_str(), &end, 0);
  if (errno != 0 || end == text.c_str() || *end != '\0' ||
      number > std::numeric_limits<std::uint32_t>::max()) {
    throw std::invalid_argument("invalid unsigned integer: " + text);
  }
  return static_cast<std::uint32_t>(number);
}

Options ReadArgs(int argc, char **argv) {
  Options options;
  for (int i = 1; i < argc; ++i) {
    std::string name = argv[i];
    const auto eq = name.find('=');
    std::string value;
    if (eq != std::string::npos) {
      value = name.substr(eq + 1);
      name.resize(eq);
    } else {
      if (i + 1 == argc) throw std::invalid_argument("missing value for " + name);
      value = argv[++i];
    }
    if (name == "--trace") options.trace = value;
    else if (name == "--bht") options.bht = value;
    else if (name == "--btb") options.btb.method = value;
    else if (name == "--btb-sets") options.btb.sets = Number(value);
    else if (name == "--btb-ways") options.btb.ways = Number(value);
    else if (name == "--btb-policy") options.btb.policy = value;
    else if (name == "--ras") options.ras.method = value;
    else if (name == "--ras-depth") options.ras.depth = Number(value);
    else throw std::invalid_argument("unknown argument: " + name);
  }
  if (options.trace.empty()) throw std::invalid_argument("missing --trace");
  return options;
}

void PrintRate(std::uint64_t hits, std::uint64_t accesses) {
  if (accesses == 0) std::printf("-");
  else std::printf("%.6f", static_cast<double>(hits) / accesses);
}

void PrintStats(const BranchStats &stats) {
  const char *names[] = {"total", "actual_taken", "actual_not_taken",
                         "predicted_taken", "predicted_not_taken"};
  const Accuracy *groups[] = {&stats.total, &stats.actual_taken,
                              &stats.actual_not_taken, &stats.predicted_taken,
                              &stats.predicted_not_taken};
  for (unsigned i = 0; i < 5; ++i) {
    const Accuracy &group = *groups[i];
    std::printf("%s accesses=%" PRIu64 " hits=%" PRIu64 " misses=%" PRIu64
                " hit_rate=", names[i], group.accesses, group.hits,
                group.accesses - group.hits);
    PrintRate(group.hits, group.accesses);
    std::printf("\n");
  }
  std::printf("direction hits=%" PRIu64 " hit_rate=", stats.direction_hits);
  PrintRate(stats.direction_hits, stats.total.accesses);
  std::printf("\n");
}

}  // namespace

int main(int argc, char **argv) {
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0) {
      Usage(argv[0]);
      return 0;
    }
  }
  try {
    const Options options = ReadArgs(argc, argv);
    auto bht = MakeBht(options.bht);
    Btb btb(options.btb);
    Ras ras(options.ras);
    BranchTraceReader reader;
    reader.Open(options.trace.c_str());
    BranchStats stats;
    BranchRecord record;
    while (reader.Next(&record)) {
      const Prediction prediction = Predict(record.input, *bht, btb, ras);
      stats.Observe(prediction, record.outcome);
      Update(record, *bht, btb, ras);
    }
    std::printf("config bht=%s btb=%s btb_sets=%u btb_ways=%u btb_policy=%s"
                " ras=%s ras_depth=%u\n", options.bht.c_str(),
                options.btb.method.c_str(), options.btb.sets, options.btb.ways,
                options.btb.policy.c_str(), options.ras.method.c_str(),
                options.ras.depth);
    PrintStats(stats);
    return 0;
  } catch (const std::invalid_argument &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 2;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
