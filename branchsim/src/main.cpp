#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>

#include "predictor.hpp"
#include "trace_reader.hpp"

namespace {

struct Options {
  std::string trace;
  std::string bht = "btfn";
  std::uint32_t bht_entries = 32;
  BtbConfig btb;
  std::uint32_t ras_entries = 0;
  std::uint32_t ras_target_bits = 16;
  std::string ras_mode = "btb";
  std::uint32_t ras_filter_entries = 2;
  std::string btb_layout = "unified";
  std::uint32_t jump_btb_sets = 1;
  std::uint32_t jump_btb_ways = 2;
  std::string split_priority = "jump";
  std::string ret_priority = "ret";
  std::uint32_t ras_filter_pc_bits = 0;
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
    else if (name == "--bht-entries") options.bht_entries = Number(value);
    else if (name == "--btb") options.btb.method = value;
    else if (name == "--btb-sets") options.btb.sets = Number(value);
    else if (name == "--btb-ways") options.btb.ways = Number(value);
    else if (name == "--btb-policy") options.btb.policy = value;
    else if (name == "--pc-bits") options.btb.pc_bits = Number(value);
    else if (name == "--target-bits") options.btb.target_bits = Number(value);
    else if (name == "--ras-entries") options.ras_entries = Number(value);
    else if (name == "--ras-target-bits") options.ras_target_bits = Number(value);
    else if (name == "--ras-mode") options.ras_mode = value;
    else if (name == "--ras-filter-entries") options.ras_filter_entries = Number(value);
    else if (name == "--btb-layout") options.btb_layout = value;
    else if (name == "--jump-btb-sets") options.jump_btb_sets = Number(value);
    else if (name == "--jump-btb-ways") options.jump_btb_ways = Number(value);
    else if (name == "--split-priority") options.split_priority = value;
    else if (name == "--ret-priority") options.ret_priority = value;
    else if (name == "--ras-filter-pc-bits") options.ras_filter_pc_bits = Number(value);
    else throw std::invalid_argument("unknown argument: " + name);
  }
  if (options.trace.empty()) throw std::invalid_argument("missing --trace");
  if (options.ras_mode != "btb" && options.ras_mode != "filter" && options.ras_mode != "ideal")
    throw std::invalid_argument("ras-mode must be btb, filter or ideal");
  if (options.ras_mode == "filter" && options.ras_filter_entries == 0)
    throw std::invalid_argument("filter mode requires positive ras-filter-entries");
  if (options.ras_entries && options.ras_mode == "btb" && options.btb.method == "none")
    throw std::invalid_argument("BTB-classified RAS requires --btb table");
  if (options.btb_layout != "unified" && options.btb_layout != "split")
    throw std::invalid_argument("btb-layout must be unified or split");
  if (options.split_priority != "jump" && options.split_priority != "branch")
    throw std::invalid_argument("split-priority must be jump or branch");
  if (options.ret_priority != "ret" && options.ret_priority != "btb")
    throw std::invalid_argument("ret-priority must be ret or btb");
  if (options.ras_filter_pc_bits > 30)
    throw std::invalid_argument("ras-filter-pc-bits must be in [0, 30]");
  if (options.btb_layout == "split" && (options.btb.method != "table" || options.ras_mode == "ideal"))
    throw std::invalid_argument("split layout requires --btb table and --ras-mode btb or filter");
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
    auto bht = MakeBht(options.bht, options.bht_entries);
    Btb btb(options.btb);
    std::unique_ptr<Btb> jump_btb;
    if (options.btb_layout == "split") {
      auto jump_config = options.btb;
      jump_config.sets = options.jump_btb_sets;
      jump_config.ways = options.jump_btb_ways;
      jump_btb = std::make_unique<Btb>(jump_config);
    }
    Ras ras(options.ras_entries, options.ras_target_bits);
    const auto return_tag_bits = options.ras_filter_pc_bits ? options.ras_filter_pc_bits : options.btb.pc_bits;
    ReturnTable return_table(ras.Enabled() && options.ras_mode == "filter" ?
                             options.ras_filter_entries : 0, return_tag_bits);
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
      Prediction prediction = Predict(record.input.pc, *bht, btb, &ras, jump_btb.get(),
                                      options.split_priority == "jump");
      btb_conflicts += prediction.btb_conflict;
      const bool is_return = instruction.kind == RV_INSTTRACE_KIND_JALR &&
                             IsRasReturn(instruction.instr);
      if (return_table.Lookup(instruction.pc)) {
        return_conflicts += prediction.btb_hit;
        // 仅按历史标签命中仲裁；BHT 预测不跳转也不能冒充表未命中。
        if (options.ret_priority == "ret" || !prediction.btb_hit)
          prediction = ras.Empty() ? Prediction{} : Prediction{true, ras.Top(instruction.pc), true};
      }
      if (ras.Enabled() && options.ras_mode == "ideal" && is_return && !ras.Empty())
        prediction = {true, ras.Top(instruction.pc), true};
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
        Update(record, *bht, btb, &ras, options.ras_mode == "btb", jump_btb.get());
      if (is_return) return_table.Update(instruction.pc);
    }
    const bool dynamic = options.bht == "bimodal" && options.btb.method != "none";
    std::printf("config bht=%s btb=%s btb_sets=%u btb_ways=%u btb_policy=%s pc_bits=%u target_bits=%u bht_entries=%u bht_ff=%" PRIu64 "\n", options.bht.c_str(),
                options.btb.method.c_str(), options.btb.sets, options.btb.ways,
                options.btb.policy.c_str(), options.btb.pc_bits, options.btb.target_bits,
                dynamic ? options.bht_entries : 0u, dynamic ? bht->StorageBits() : 0u);
    PrintStats(stats, instructions);
    std::printf("btb_layout mode=%s jump_sets=%u jump_ways=%u priority=%s conflicts=%" PRIu64 "\n",
                options.btb_layout.c_str(), jump_btb ? options.jump_btb_sets : 0,
                jump_btb ? options.jump_btb_ways : 0, options.split_priority.c_str(), btb_conflicts);
    std::printf("ras entries=%u target_bits=%u mode=%s storage_bits=%" PRIu64
                " pushes=%" PRIu64 " pops=%" PRIu64 " eligible=%" PRIu64
                " available=%" PRIu64 " predictions=%" PRIu64 " correct=%" PRIu64
                " overflows=%" PRIu64 " underflows=%" PRIu64 "\n",
                options.ras_entries, options.ras_target_bits, options.ras_mode.c_str(),
                ras.StorageBits(), pushes, pops, eligible, available, ras_predictions,
                ras_correct, ras.overflows, ras.underflows);
    std::printf("returns accesses=%" PRIu64 " hits=%" PRIu64 " misses=%" PRIu64 "\n",
                returns.accesses, returns.hits, returns.accesses - returns.hits);
    std::printf("return_table entries=%u storage_bits=%" PRIu64 " priority=%s conflicts=%" PRIu64 " tag_bits=%u\n",
                ras.Enabled() && options.ras_mode == "filter" ? options.ras_filter_entries : 0,
                return_table.StorageBits(), options.ret_priority.c_str(), return_conflicts,
                ras.Enabled() && options.ras_mode == "filter" ? return_tag_bits : 0);
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
