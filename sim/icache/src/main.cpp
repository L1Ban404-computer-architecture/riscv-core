#include "cache.hpp"
#include "simulation.hpp"
#include "synthesis.hpp"

namespace {
namespace json = sim::json;

json::object Simulate(const json::object &parameters, insttrace::Reader &reader,
                      const std::filesystem::path &output) {
  sim::RequireKeys(parameters, {"sets", "ways", "block_bytes", "policy", "miss_head_cycles", "miss_beat_cycles"});
  CacheConfig config;
  config.sets = sim::Uint32(parameters, "sets");
  config.ways = sim::Uint32(parameters, "ways");
  config.block_bytes = sim::Uint32(parameters, "block_bytes");
  config.policy = ParseReplacementPolicy(sim::String(parameters, "policy"));
  const double head = sim::NonnegativeNumber(parameters, "miss_head_cycles");
  const double beat = sim::NonnegativeNumber(parameters, "miss_beat_cycles");
  Cache cache(config);
  insttrace::Record record;
  while (reader.Next(&record)) cache.Access(record.pc);

  const auto &stats = cache.stats();
  const double penalty = head + beat * (config.block_bytes / 4 - 1);
  json::object metrics = {{"accesses", stats.accesses}, {"hits", stats.hits}, {"misses", stats.misses},
          {"hit_rate", sim::Ratio(stats.hits, stats.accesses)},
          {"bytes", std::uint64_t(config.sets) * config.ways * config.block_bytes},
          {"miss_penalty_cycles", penalty},
          {"amt", stats.accesses ? json::value(double(stats.misses) / stats.accesses * penalty) : json::value(nullptr)}};
  for (const auto &entry : Synthesize(config, output.parent_path() / "synth" / output.stem()))
    metrics[entry.key()] = entry.value();
  return metrics;
}
}  // namespace

int main(int argc, char **argv) { return sim::Run(argc, argv, Simulate); }
