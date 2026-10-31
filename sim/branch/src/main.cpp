#include "predictor.hpp"
#include "simulation.hpp"
#include "trace_validation.hpp"

namespace {
namespace json = sim::json;

json::object Simulate(const json::object &input_parameters, insttrace::Reader &reader,
                      const std::filesystem::path &) {
  // 旧配置默认保持共用 BTB。
  auto parameters = input_parameters;
  if (!parameters.contains("jal_btb")) parameters["jal_btb"] = false;
  if (!parameters.contains("jal_btb_entries")) parameters["jal_btb_entries"] = 4;
  sim::RequireKeys(parameters, {"bht", "bht_entries", "btb", "sets", "ways",
                                "policy", "pc_bits", "target_bits", "jal_btb", "jal_btb_entries"});
  BtbConfig config;
  config.method = sim::String(parameters, "btb");
  config.sets = sim::Uint32(parameters, "sets");
  config.ways = sim::Uint32(parameters, "ways");
  config.policy = sim::String(parameters, "policy");
  config.pc_bits = sim::Uint32(parameters, "pc_bits");
  config.target_bits = sim::Uint32(parameters, "target_bits");
  config.jal_btb = parameters.at("jal_btb").as_bool();
  config.jal_btb_entries = sim::Uint32(parameters, "jal_btb_entries");
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
  const std::uint64_t jal_entries = entries && config.jal_btb ? config.jal_btb_entries : 0;
  const auto replacement = [&config](std::uint32_t sets, std::uint32_t ways) {
    std::uint32_t way_bits = 0;
    for (auto remaining = ways - 1; remaining != 0; remaining >>= 1) ++way_bits;
    return (config.policy == "rr" ? std::uint64_t(sets) : std::uint64_t(sets) * ways) * way_bits;
  };
  // 省略目标恒零位；独立表省去 kind，仅条件分支的 BTFN 需要 backward 位。
  const auto entry_bits = entries ? config.pc_bits + config.target_bits + !config.jal_btb + (method == "btfn") : 0;
  const auto replacement_bits = entries ? replacement(config.sets, config.ways) : 0;
  const auto jal_entry_bits = jal_entries ? config.pc_bits + config.target_bits : 0;
  const auto jal_replacement_bits = jal_entries ? replacement(1, config.jal_btb_entries) : 0;
  const auto jal_btb_ff = jal_entries * jal_entry_bits + jal_replacement_bits;
  const auto btb_ff = entries * entry_bits + replacement_bits + jal_btb_ff;
  const auto bht_ff = entries ? bht->StorageBits() : 0;
  json::object metrics = {{"instructions", stats.total.accesses}, {"entries", entries},
                          {"entry_bits", entry_bits}, {"replacement_bits", replacement_bits},
                          {"jal_entries", jal_entries}, {"jal_entry_bits", jal_entry_bits},
                          {"jal_replacement_bits", jal_replacement_bits}, {"jal_btb_ff", jal_btb_ff},
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
