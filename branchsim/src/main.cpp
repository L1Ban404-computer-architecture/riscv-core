#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>

#include "predictor.hpp"
#include "trace_reader.hpp"

namespace {

struct Options {
  std::string trace;
  PredictorConfig predictor;
};

void Usage(const char *prog) {
  std::printf(
      "Usage: %s --trace PATH [options]\n"
      "  --bht not-taken|btfn|bimodal  default btfn\n"
      "  --bht-entries N           bimodal counters, default 32 (power of two)\n"
      "  --btb none|table          default table\n"
      "  --btb-sets N              default 64 (positive power of two)\n"
      "  --btb-ways N              default 2\n"
      "  --btb-policy rr|lru       default rr\n"
      "  --pc-bits N               default 8 (PC[N+1:2], range 1..30)\n"
      "  --target-bits N           default 16 (target low N bits, range 2..32)\n"
      "  --ras-entries N           default 0 (disabled); power of two <= 64\n"
      "  --ras-target-bits N       default 16 (return address low bits, 2..32)\n"
      "  --ras-mode btb|filter|ideal default btb; ideal uses decoded return oracle\n"
      "  --ras-filter-entries N    default 2 (filter mode, power of two <= 64)\n"
      "  --btb-layout unified|split default unified; split keeps BRANCH separate\n"
      "  --jump-btb-sets N         split JAL/RET sets, default 1\n"
      "  --jump-btb-ways N         split JAL/RET ways, default 2\n"
      "  --split-priority jump|branch default jump on both tables matching\n"
      "  --ret-priority ret|btb    filter mode arbitration, default ret\n"
      "  --ras-filter-pc-bits N    RET tag width; default 0 follows --pc-bits\n"
      "  split + ras-mode filter separates BRANCH, JAL and RET tables\n", prog);
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
  auto &config = options.predictor;
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
    else if (name == "--bht") config.bht = value;
    else if (name == "--bht-entries") config.bht_entries = Number(value);
    else if (name == "--btb") config.btb.method = value;
    else if (name == "--btb-sets") config.btb.sets = Number(value);
    else if (name == "--btb-ways") config.btb.ways = Number(value);
    else if (name == "--btb-policy") config.btb.policy = value;
    else if (name == "--pc-bits") config.btb.pc_bits = Number(value);
    else if (name == "--target-bits") config.btb.target_bits = Number(value);
    else if (name == "--ras-entries") config.ras_entries = Number(value);
    else if (name == "--ras-target-bits") config.ras_target_bits = Number(value);
    else if (name == "--ras-mode") config.ras_mode = value;
    else if (name == "--ras-filter-entries") config.ras_filter_entries = Number(value);
    else if (name == "--btb-layout") config.btb_layout = value;
    else if (name == "--jump-btb-sets") config.jump_btb_sets = Number(value);
    else if (name == "--jump-btb-ways") config.jump_btb_ways = Number(value);
    else if (name == "--split-priority") config.split_priority = value;
    else if (name == "--ret-priority") config.ret_priority = value;
    else if (name == "--ras-filter-pc-bits") config.ras_filter_pc_bits = Number(value);
    else throw std::invalid_argument("unknown argument: " + name);
  }
  if (options.trace.empty()) throw std::invalid_argument("missing --trace");
  return options;
}

void PrintRate(std::uint64_t hits, std::uint64_t accesses) {
  if (accesses == 0) std::printf("-");
  else std::printf("%.6f", static_cast<double>(hits) / accesses);
}

void PrintStats(const BranchStats &stats, std::uint64_t instructions) {
  const struct {
    const char *name;
    const Accuracy &accuracy;
  } groups[] = {
    {"total", stats.total},
    {"control_flow", stats.control_flow},
    {"non_control_flow", stats.non_control_flow},
    {"actual_taken", stats.actual_taken},
    {"actual_not_taken", stats.actual_not_taken},
    {"predicted_taken", stats.predicted_taken},
    {"predicted_not_taken", stats.predicted_not_taken},
  };
  for (const auto &entry : groups) {
    const Accuracy &group = entry.accuracy;
    std::printf("%s accesses=%" PRIu64 " hits=%" PRIu64 " misses=%" PRIu64
                " hit_rate=", entry.name, group.accesses, group.hits,
                group.accesses - group.hits);
    PrintRate(group.hits, group.accesses);
    std::printf("\n");
  }
  std::printf("direction hits=%" PRIu64 " hit_rate=", stats.direction_hits);
  PrintRate(stats.direction_hits, stats.total.accesses);
  std::printf("\n");
  const std::uint64_t mispredictions = stats.total.accesses - stats.total.hits;
  std::printf("instructions=%" PRIu64 " mpki=", instructions);
  if (instructions == 0) std::printf("-");
  else {
    std::printf("%.6f", 1000.0 * mispredictions / static_cast<double>(instructions));
  }
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
    const auto &config = options.predictor;
    Predictor predictor(config);
    const auto &ras = predictor.ras();
    const auto &return_table = predictor.return_table();
    const auto return_tag_bits = config.ras_filter_pc_bits ? config.ras_filter_pc_bits : config.btb.pc_bits;
    TraceReader reader;
    reader.Open(options.trace.c_str());
    BranchStats stats;
    TraceRecord instruction;
    std::uint64_t instructions = 0;
    Accuracy returns, other_jalr, branches, jals;
    std::uint64_t pushes = 0, pops = 0, eligible = 0, available = 0;
    std::uint64_t ras_predictions = 0, ras_correct = 0, redirects = 0;
    std::uint64_t btb_conflicts = 0;
    std::uint64_t return_conflicts = 0;
    while (reader.Next(&instruction)) {
      ++instructions;
      const BranchRecord record = {{instruction.pc, instruction.instr},
                                   {instruction.target, instruction.taken}};
      const bool is_return = instruction.kind == RV_INSTTRACE_KIND_JALR &&
                             IsRasReturn(instruction.instr);
      const Prediction prediction = config.ras_mode == "ideal" ?
          predictor.PredictIdeal(record.input.pc, is_return) : predictor.Predict(record.input.pc);
      btb_conflicts += prediction.btb_conflict;
      return_conflicts += prediction.return_conflict;
      const bool correct = prediction.taken == record.outcome.taken &&
                           (!record.outcome.taken || prediction.target == record.outcome.target);
      const auto action = instruction.kind == RV_INSTTRACE_KIND_NONE ? RasAction{} :
                          DecodeRasAction(instruction.instr);
      pushes += action.push;
      pops += action.pop;
      eligible += is_return;
      available += is_return && !ras.Empty();
      ras_predictions += prediction.ras;
      ras_correct += prediction.ras && correct;
      if (is_return) returns.Observe(correct);
      else if (instruction.kind == RV_INSTTRACE_KIND_JALR) other_jalr.Observe(correct);
      else if (instruction.kind == RV_INSTTRACE_KIND_BRANCH) branches.Observe(correct);
      else if (instruction.kind == RV_INSTTRACE_KIND_JAL) jals.Observe(correct);
      // 贴近当前 RTL：非 RAS 来源的 JALR 即使偶然命中目标仍强制改道。
      redirects += !correct || (instruction.kind == RV_INSTTRACE_KIND_JALR && !prediction.ras);
      stats.Observe(prediction, record.outcome, instruction.kind != RV_INSTTRACE_KIND_NONE);
      if (instruction.kind != RV_INSTTRACE_KIND_NONE)
        predictor.Update(record);
    }
    const bool dynamic = config.bht == "bimodal" && config.btb.method != "none";
    std::printf("config bht=%s btb=%s btb_sets=%u btb_ways=%u btb_policy=%s pc_bits=%u target_bits=%u bht_entries=%u bht_ff=%" PRIu64 "\n", config.bht.c_str(),
                config.btb.method.c_str(), config.btb.sets, config.btb.ways,
                config.btb.policy.c_str(), config.btb.pc_bits, config.btb.target_bits,
                dynamic ? config.bht_entries : 0u, dynamic ? predictor.bht().StorageBits() : 0u);
    PrintStats(stats, instructions);
    std::printf("btb_layout mode=%s jump_sets=%u jump_ways=%u priority=%s conflicts=%" PRIu64 "\n",
                config.btb_layout.c_str(), config.btb_layout == "split" ? config.jump_btb_sets : 0,
                config.btb_layout == "split" ? config.jump_btb_ways : 0, config.split_priority.c_str(), btb_conflicts);
    std::printf("ras entries=%u target_bits=%u mode=%s storage_bits=%" PRIu64
                " pushes=%" PRIu64 " pops=%" PRIu64 " eligible=%" PRIu64
                " available=%" PRIu64 " predictions=%" PRIu64 " correct=%" PRIu64
                " overflows=%" PRIu64 " underflows=%" PRIu64 "\n",
                config.ras_entries, config.ras_target_bits, config.ras_mode.c_str(),
                ras.StorageBits(), pushes, pops, eligible, available, ras_predictions,
                ras_correct, ras.overflows, ras.underflows);
    std::printf("returns accesses=%" PRIu64 " hits=%" PRIu64 " misses=%" PRIu64 "\n",
                returns.accesses, returns.hits, returns.accesses - returns.hits);
    std::printf("return_table entries=%u storage_bits=%" PRIu64 " priority=%s conflicts=%" PRIu64 " tag_bits=%u\n",
                ras.Enabled() && config.ras_mode == "filter" ? config.ras_filter_entries : 0,
                return_table.StorageBits(), config.ret_priority.c_str(), return_conflicts,
                ras.Enabled() && config.ras_mode == "filter" ? return_tag_bits : 0);
    std::printf("other_jalr accesses=%" PRIu64 " hits=%" PRIu64 " misses=%" PRIu64 "\n",
                other_jalr.accesses, other_jalr.hits, other_jalr.accesses - other_jalr.hits);
    std::printf("branches accesses=%" PRIu64 " hits=%" PRIu64 " misses=%" PRIu64 "\n",
                branches.accesses, branches.hits, branches.accesses - branches.hits);
    std::printf("jals accesses=%" PRIu64 " hits=%" PRIu64 " misses=%" PRIu64 "\n",
                jals.accesses, jals.hits, jals.accesses - jals.hits);
    std::printf("redirects count=%" PRIu64 " per_ki=", redirects);
    if (instructions) std::printf("%.6f\n", 1000.0 * redirects / instructions);
    else std::printf("-\n");
    return 0;
  } catch (const std::invalid_argument &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 2;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
