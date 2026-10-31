#include "predictor.hpp"
#include "simulation.hpp"
#include "trace_validation.hpp"

namespace {
namespace json = sim::json;

json::object Simulate(const json::object &parameters, insttrace::Reader &reader,
                      const std::filesystem::path &) {
  sim::RequireKeys(parameters, {"bht", "bht_entries", "btb", "sets", "ways",
                                "policy", "pc_bits", "target_bits"});
  BtbConfig config;
  config.method = sim::String(parameters, "btb");
  config.sets = sim::Uint32(parameters, "sets");
  config.ways = sim::Uint32(parameters, "ways");
  config.policy = sim::String(parameters, "policy");
  config.pc_bits = sim::Uint32(parameters, "pc_bits");
  config.target_bits = sim::Uint32(parameters, "target_bits");
  const auto method = sim::String(parameters, "bht");
  auto bht = MakeBht(method, sim::Uint32(parameters, "bht_entries"));
  Btb btb(config);

  BranchStats stats;
  insttrace::Record instruction;
  while (reader.Next(&instruction)) {
    ValidateTraceRecord(instruction, reader.gpr_count());
    const Prediction prediction = Predict(instruction.pc, *bht, btb);
    stats.Observe(prediction, instruction);
    Update(instruction, *bht, btb);
  }

  const std::uint64_t entries = config.method == "none" ? 0 : std::uint64_t(config.sets) * config.ways;
  // 与 RTL 的表项位数一致：省略目标恒零位，仅 BTFN 需要额外的 backward 位。
  std::uint32_t way_bits = 0;
  for (auto ways = config.ways - 1; ways != 0; ways >>= 1) ++way_bits;
  const auto entry_bits = entries ? config.pc_bits + config.target_bits + 1 + (method == "btfn") : 0;
  const auto replacement_bits = !entries ? 0 :
      (config.policy == "rr" ? std::uint64_t(config.sets) : entries) * way_bits;
  const auto btb_ff = entries * entry_bits + replacement_bits;
  const auto bht_ff = entries ? bht->StorageBits() : 0;
  json::object metrics = {{"instructions", stats.total.accesses}, {"entries", entries},
                          {"entry_bits", entry_bits}, {"replacement_bits", replacement_bits},
                          {"btb_ff", btb_ff}, {"bht_ff", bht_ff}, {"total_ff", btb_ff + bht_ff},
                          {"direction_hits", stats.direction_hits},
                          {"direction_hit_rate", sim::Ratio(stats.direction_hits, stats.total.accesses)}};
  const struct { const char *name; const Accuracy &accuracy; } groups[] = {
      {"total", stats.total}, {"control_flow", stats.control_flow},
      {"non_control_flow", stats.non_control_flow}, {"actual_taken", stats.actual_taken},
      {"actual_not_taken", stats.actual_not_taken}, {"predicted_taken", stats.predicted_taken},
      {"predicted_not_taken", stats.predicted_not_taken}};
  for (const auto &group : groups) {
    const auto &counts = group.accuracy;
    const std::string prefix = std::string(group.name) + "_";
    metrics[prefix + "accesses"] = counts.accesses;
    metrics[prefix + "hits"] = counts.hits;
    metrics[prefix + "misses"] = counts.accesses - counts.hits;
    metrics[prefix + "hit_rate"] = sim::Ratio(counts.hits, counts.accesses);
  }
  metrics["mpki"] = stats.total.accesses ?
      json::value(1000.0 * (stats.total.accesses - stats.total.hits) / stats.total.accesses) : json::value(nullptr);
  return metrics;
}
}  // namespace

int main(int argc, char **argv) { return sim::Run(argc, argv, Simulate); }
