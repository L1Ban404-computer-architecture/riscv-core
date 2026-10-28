#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>

#include "predictor.hpp"

namespace {

void Check(bool condition, const char *message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::exit(1);
  }
}

BtbConfig Config(std::uint32_t sets = 1, std::uint32_t ways = 1,
                 const char *policy = "rr", std::uint32_t pc_bits = 8,
                 std::uint32_t target_bits = 16) {
  BtbConfig config;
  config.sets = sets;
  config.ways = ways;
  config.policy = policy;
  config.pc_bits = pc_bits;
  config.target_bits = target_bits;
  return config;
}

void TagAndTargetReconstruction() {
  Btb btb(Config(2, 2));
  btb.Update(0x12340124, 0x9999beec, BtbType::kJal);
  Check(btb.Lookup(0x12340124).target == 0x1234beec,
        "target high bits must come from lookup PC, not training target");
  const auto alias = btb.Lookup(0xabcd0524);
  Check(alias.hit && alias.target == 0xabcdbeec,
        "8-bit tag must match PC[9:2], and 16-bit target must splice lookup PC[31:16]");
  Check(btb.Lookup(0x12340124 ^ 0x400).hit,
        "PC bit 10 must not participate in an 8-bit tag");
  Check(!btb.Lookup(0x12340124 ^ 0x200).hit,
        "PC bit 9 must participate in an 8-bit tag");
  Check(!btb.Lookup(0x12340124 ^ 0x4).hit,
        "PC bit 2 must participate in the tag and set lookup");
}

void AliasedTrainingMergesEntry() {
  Btb btb(Config(1, 2));
  btb.Update(0x1000, 0x2010, BtbType::kBranch);
  btb.Update(0x1004, 0x2020, BtbType::kBranch);
  btb.Update(0x1400, 0x3030, BtbType::kJal);
  Check(btb.Lookup(0x1000).target == 0x3030 &&
        btb.Lookup(0x1000).type == BtbType::kJal,
        "aliased training must update the matching truncated tag");
  Check(btb.Lookup(0x1004).hit,
        "aliased training must not consume another way or evict the other tag");
  btb.Update(0x1008, 0x3040, BtbType::kJal);
  Check(!btb.Lookup(0x1000).hit && btb.Lookup(0x1004).hit,
        "RR pointer must not advance when an alias updates an existing entry");
}

void SetIndexStillSeparatesEntries() {
  Btb btb(Config(8, 1, "rr", 1));
  btb.Update(0x1000, 0x2000, BtbType::kJal);
  Check(!btb.Lookup(0x1008).hit,
        "equal short tags in different sets must not match");
}

void BtfDirectionSurvivesTargetTruncation() {
  auto btfn = MakeBht("btfn");
  auto not_taken = MakeBht("not-taken");
  Btb btb(Config());
  btb.Update(0x10010004, 0x1000fffc, BtbType::kBranch);
  const auto entry = btb.Lookup(0x10010004);
  Check(entry.backward, "backward bit must describe the original training target");
  const Prediction prediction = Predict(0x10010004, *btfn, btb);
  Check(prediction.taken && prediction.target == 0x1001fffc,
        "cross-segment backward branch must keep direction even when reconstructed target is forward");
  BranchStats stats;
  stats.Observe(prediction, {0x1000fffc, true}, true);
  Check(stats.direction_hits == 1 && stats.total.hits == 0,
        "correct direction with a truncated wrong target must remain a full prediction miss");
  Check(!Predict(0x10010004, *not_taken, btb).taken,
        "not-taken BHT must suppress conditional branches");

  btb.Update(0x1000fffc, 0x10010004, BtbType::kBranch);
  Check(!btb.Lookup(0x1000fffc).backward &&
        !Predict(0x1000fffc, *btfn, btb).taken,
        "cross-segment forward branch must not become backward after truncation");
  btb.Update(0x1000fffc, 0x10010004, BtbType::kJal);
  Check(Predict(0x1000fffc, *not_taken, btb).taken,
        "JAL prediction must remain independent of the conditional BHT");
}

void OrdinaryInstructionFalseRedirect() {
  auto bht = MakeBht("btfn");
  Btb btb(Config());
  btb.Update(0x1000, 0x1080, BtbType::kJal);
  const Prediction prediction = Predict(0x1400, *bht, btb);
  Check(prediction.taken, "ordinary instruction may falsely hit a partial BTB tag");
  BranchStats stats;
  stats.Observe(prediction, {0, false}, false);
  Check(stats.total.accesses == 1 && stats.total.hits == 0 &&
        stats.non_control_flow.accesses == 1 && stats.non_control_flow.hits == 0 &&
        stats.control_flow.accesses == 0 && stats.direction_hits == 0,
        "ordinary false redirects must count as prediction errors");
  const BranchRecord ordinary = {{0x1400, 0x00000013}, {0, false}};
  Update(ordinary, *bht, btb);
  Check(btb.Lookup(0x1000).target == 0x1080,
        "ordinary retirement must not train over a colliding BTB entry");
  stats.Observe({}, {0x8080, false}, true);
  Check(stats.total.accesses == 2 && stats.total.hits == 1 &&
        stats.control_flow.accesses == 1 && stats.control_flow.hits == 1,
        "untaken predictions compare direction without comparing unused target");
}

void WidthBoundariesAndValidation() {
  Btb btb(Config(1, 1, "rr", 30, 32));
  btb.Update(0xfffffffc, 0x00000004, BtbType::kJal);
  Check(btb.Lookup(0xfffffffc).target == 4,
        "32-bit target must be preserved without undefined full-width shift");
  Check(!btb.Lookup(0xfffffbfc).hit,
        "30-bit source tag must distinguish all aligned RV32 PCs");
  Btb smallest(Config(1, 1, "rr", 1, 2));
  smallest.Update(0x12345678, 0xfffffff2, BtbType::kJal);
  Check(smallest.Lookup(0x12345678).target == 0x1234567a,
        "target width counts actual low PC bits, including bit 1");
  for (const auto width : {0u, 31u, 32u}) {
    bool rejected = false;
    try { Btb invalid(Config(1, 1, "rr", width, 16)); }
    catch (const std::invalid_argument &) { rejected = true; }
    Check(rejected, "PC widths outside 1..30 must be rejected");
  }
  for (const auto width : {0u, 1u, 33u}) {
    bool rejected = false;
    try { Btb invalid(Config(1, 1, "rr", 8, width)); }
    catch (const std::invalid_argument &) { rejected = true; }
    Check(rejected, "target widths outside 2..32 must be rejected");
  }
}

void NonPowerOfTwoReplacement() {
  for (const char *policy : {"rr", "lru"}) {
    Btb btb(Config(1, 3, policy, 30, 32));
    for (std::uint32_t i = 0; i < 3; ++i) {
      btb.Update(0x1000 + 4 * i, 0x2000 + 4 * i, BtbType::kJal);
    }
    Check(btb.Lookup(0x1000).hit, "initial three-way table must hold all entries");
    btb.Update(0x100c, 0x200c, BtbType::kJal);
    Check(!btb.Lookup(0x1000).hit,
          "lookup must not refresh replacement state before fourth insertion");
    btb.Update(0x1004, 0x2004, BtbType::kJal);
    btb.Update(0x1010, 0x2010, BtbType::kJal);
    const bool lru = policy[0] == 'l';
    Check(btb.Lookup(0x1004).hit == lru && btb.Lookup(0x1008).hit != lru,
          "LRU training refresh and RR insertion order must work with three ways");
    Check(btb.Lookup(0x100c).hit && btb.Lookup(0x1010).hit,
          "replacement must preserve the other resident and new entry");
  }
}

void BimodalLearningAndAliasing() {
  auto bht = MakeBht("bimodal", 4);
  Check(bht->StorageBits() == 8, "four two-bit counters occupy eight logical bits");
  Check(!bht->Predict(0x1000, true), "bimodal starts weakly not-taken, independent of backward");
  bht->Update(0x1000, 0x1008, true);
  Check(bht->Predict(0x1000, false), "one taken outcome moves weak not-taken into weak taken");
  Check(!bht->Predict(0x1004, true), "a distinct PC index has independent state");
  bht->Update(0x1000, 0x1008, true);
  bht->Update(0x1000, 0x1008, true);
  bht->Update(0x1000, 0x1008, false);
  Check(bht->Predict(0x1000, false), "saturated taken tolerates a single contrary outcome");
  bht->Update(0x1010, 0x1018, false);
  Check(!bht->Predict(0x1000, false), "PC aliases share a counter without hidden tags");
  for (int i = 0; i < 8; ++i) bht->Update(0x1000, 0x1008, false);
  bht->Update(0x1000, 0x1008, true);
  Check(!bht->Predict(0x1000, false), "saturated not-taken needs two taken outcomes to flip");
  Btb btb(Config(1, 2, "rr", 30, 32));
  const BranchRecord branch = {{0x2000, 0x00000463}, {0x2008, true}};
  auto learned = MakeBht("bimodal", 4);
  auto btfn = MakeBht("btfn");
  Check(!Predict(0x2000, *learned, btb).taken, "no target may be predicted before BTB training");
  Update(branch, *learned, btb);
  Check(Predict(0x2000, *learned, btb).taken && !Predict(0x2000, *btfn, btb).taken,
        "bimodal learns a taken forward branch that BTFN always predicts not-taken");
  const BranchRecord jal = {{0x2004, 0x0000006f}, {0x2004, true}};
  Update(jal, *learned, btb);
  Check(!learned->Predict(0x2004, false), "JAL must not train conditional direction counters");
  const BranchRecord jalr = {{0x2008, 0x00008067}, {0x3000, true}};
  Update(jalr, *learned, btb);
  Check(!learned->Predict(0x2008, false), "JALR must not train conditional direction counters");
  for (const auto count : {0u, 3u}) {
    bool rejected = false;
    try { auto invalid = MakeBht("bimodal", count); }
    catch (const std::invalid_argument &) { rejected = true; }
    Check(rejected, "bimodal table size must be a positive power of two");
  }
}

}  // namespace

int main() {
  TagAndTargetReconstruction();
  AliasedTrainingMergesEntry();
  SetIndexStillSeparatesEntries();
  BtfDirectionSurvivesTargetTruncation();
  OrdinaryInstructionFalseRedirect();
  WidthBoundariesAndValidation();
  NonPowerOfTwoReplacement();
  BimodalLearningAndAliasing();
  std::puts("PASS: 8 branchsim model regression groups");
  return 0;
}
