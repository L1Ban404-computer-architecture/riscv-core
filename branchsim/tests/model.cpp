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

std::uint32_t Jalr(unsigned rd, unsigned rs1, unsigned imm = 0) {
  return (imm << 20) | (rs1 << 15) | (rd << 7) | 0x67u;
}

void RasHints() {
  for (unsigned rd : {0u, 1u, 5u, 6u}) {
    for (unsigned rs1 : {0u, 1u, 5u, 6u}) {
      const auto action = DecodeRasAction(Jalr(rd, rs1));
      const bool dst = rd == 1 || rd == 5, src = rs1 == 1 || rs1 == 5;
      Check(action.push == dst && action.pop == (src && (!dst || rd != rs1)),
            "JALR hint table must cover x1/x5, same-link fusion and coroutine exchange");
    }
  }
  Check(DecodeRasAction(0xef).push && DecodeRasAction(0x2ef).push &&
        !DecodeRasAction(0x6f).push && !DecodeRasAction(0x13).push,
        "only JAL x1/x5 push, tail calls and ordinary instructions do not");
  Check(IsRasReturn(Jalr(0, 1)) && IsRasReturn(Jalr(1, 5)) &&
        !IsRasReturn(Jalr(0, 1, 4)) && DecodeRasAction(Jalr(0, 1, 4)).pop,
        "nonzero JALR immediate keeps its pop hint but is not classified as a plain return");
}

void RasBoundedStack() {
  Ras ras(2, 16);
  const auto push = [&](std::uint32_t pc) { ras.Update({pc, 0xef}); };
  const auto pop = [&]() { ras.Update({0x1000, Jalr(0, 1)}); };
  Check(ras.Empty() && ras.StorageBits() == 31, "2-entry low16 RAS costs 28+1+2 bits");
  push(0x1000); push(0x2000); push(0x3000);
  Check(ras.Top(0xabcd0000) == 0xabcd3004 && ras.overflows == 1,
        "overflow must retain newest return and reconstruct high bits from query PC");
  pop();
  Check(ras.Top(0) == 0x2004, "ring overflow must keep the next newest return");
  ras.Update({0x4000, Jalr(1, 5)});
  Check(ras.Top(0) == 0x4004 && ras.overflows == 1,
        "pop+push must replace top without another overflow");
  pop(); pop();
  Check(ras.Empty() && ras.underflows == 1,
        "discarded oldest entry must not reappear after overflow and drain");
  Ras single(1, 32);
  single.Update({0xfffffffcu, 0xef});
  Check(single.Top(0x12340000) == 0 && single.StorageBits() == 31,
        "full32 supports PC+4 wraparound and one entry needs only a valid count");
  single.Clear();
  Check(single.Empty(), "clear invalidates stack without resetting data");
  Check(Ras().StorageBits() == 0, "disabled RAS costs zero");
  for (const auto size : {3u, 65u}) {
    bool rejected = false;
    try { Ras invalid(size); } catch (const std::invalid_argument &) { rejected = true; }
    Check(rejected, "RAS rejects unsupported sizes");
  }
}

void RasPredictionAndPollution() {
  auto bht = MakeBht("bimodal", 16);
  Btb btb(Config(1, 2, "rr", 10, 16));
  Ras ras(2);
  const BranchRecord call = {{0x1000, 0xef}, {0x2000, true}};
  const BranchRecord ret = {{0x2100, Jalr(0, 1)}, {0x1004, true}};
  Update(call, *bht, btb, &ras);
  Check(!Predict(ret.input.pc, *bht, btb, &ras).taken,
        "cold return cannot be recognized using current instruction as an oracle");
  Update(ret, *bht, btb, &ras);
  Check(!Predict(ret.input.pc, *bht, btb, &ras).taken,
        "empty RAS must fall through even with a learned return BTB entry");
  Update(call, *bht, btb, &ras);
  const auto prediction = Predict(ret.input.pc, *bht, btb, &ras);
  Check(prediction.ras && prediction.target == 0x1004 && ras.Top(0) == 0x1004,
        "query selects return target and never pops speculatively");
  const auto alias = Predict(ret.input.pc + 0x1000, *bht, btb, &ras);
  BranchStats stats;
  stats.Observe(alias, {0, false}, false);
  Check(alias.ras && stats.non_control_flow.hits == 0,
        "return tag aliases on ordinary instructions must count as false redirects");
  Update({{0x2200, 0x6f}, {0x2300, true}}, *bht, btb, &ras);
  Update({{0x2300, 0x6f}, {0x2400, true}}, *bht, btb, &ras);
  Check(!btb.Lookup(ret.input.pc).hit, "returns must compete for real BTB capacity");
  Check(ras.Top(0) == 0x1004, "tail JALs must not change RAS");
}

void ReturnTableCapacityAndAliases() {
  ReturnTable table(2, 10);
  Check(table.StorageBits() == 23 && !table.Lookup(0x1000),
        "2 return tags cost 22 bits plus a one-bit RR pointer and start invalid");
  table.Update(0x1000); table.Update(0x1004);
  table.Update(0x2000);
  Check(table.Lookup(0x1000) && table.Lookup(0x1004),
        "truncated return alias must share its entry without advancing replacement");
  table.Update(0x1008);
  Check(!table.Lookup(0x1000) && table.Lookup(0x1004) && table.Lookup(0x1008),
        "new return site evicts oldest RR tag, not the aliased hit's neighbor");
  Check(ReturnTable(1, 10).StorageBits() == 11 && ReturnTable(0, 10).StorageBits() == 0,
        "one return tag needs no replacement bits; disabled detector costs zero");
}

void SplitBtbTrainingAndIsolation() {
  auto bht = MakeBht("bimodal", 16);
  Btb branches(Config(1, 1, "rr", 10));
  Btb jumps(Config(1, 2, "rr", 10));
  Ras ras(2);
  const BranchRecord branch = {{0x1000, 0x63}, {0x0ffc, true}};
  const BranchRecord call = {{0x1100, 0xef}, {0x2000, true}};
  const BranchRecord ret = {{0x2200, Jalr(0, 1)}, {0x1104, true}};
  Update(branch, *bht, branches, &ras, true, &jumps);
  Check(branches.Lookup(0x1000).hit && !jumps.Lookup(0x1000).hit,
        "conditional branch trains only branch BTB");
  Update(call, *bht, branches, &ras, true, &jumps);
  Update(ret, *bht, branches, &ras, true, &jumps);
  Check(branches.Lookup(0x1000).hit && !branches.Lookup(0x1100).hit &&
        jumps.Lookup(0x1100).type == BtbType::kJal &&
        jumps.Lookup(0x2200).type == BtbType::kReturn,
        "JAL and RET share jump BTB without evicting the branch BTB");
  Update({{0x2100, Jalr(0, 1)}, {0x1104, true}}, *bht, branches, &ras, true, &jumps);
  Check(jumps.Lookup(0x1100).type == BtbType::kReturn,
        "same-table JAL/RET aliases merge exactly like the original BTB");
}

void SplitBtbLookupArbitration() {
  auto bht = MakeBht("bimodal", 16);
  Btb branches(Config(1, 2, "rr", 10));
  Btb jumps(Config(1, 2, "rr", 10));
  Ras ras(2);
  branches.Update(0x1000, 0x0800, BtbType::kBranch);
  jumps.Update(0x2000, 0x2400, BtbType::kJal);
  auto prediction = Predict(0x1000, *bht, branches, &ras, &jumps);
  Check(prediction.btb_conflict && prediction.taken && prediction.target == 0x2400,
        "jump priority resolves two matching tags using historical state only");
  prediction = Predict(0x1000, *bht, branches, &ras, &jumps, false);
  Check(prediction.btb_hit && prediction.btb_conflict && !prediction.taken,
        "branch hit predicted not-taken must still win branch-priority arbitration");
  jumps.Update(0x2000, 0, BtbType::kReturn);
  prediction = Predict(0x1000, *bht, branches, &ras, &jumps);
  Check(prediction.btb_conflict && !prediction.taken,
        "empty RAS suppresses jump prediction without falling back to the other table");
  ras.Update({0x3000, 0xef});
  prediction = Predict(0x1000, *bht, branches, &ras, &jumps);
  Check(prediction.ras && prediction.target == 0x3004 && ras.Top(0) == 0x3004,
        "split return uses non-speculative RAS target");
}

void CompletePredictorArbitration() {
  PredictorConfig config;
  config.bht = "bimodal";
  config.btb = Config(1, 1, "rr", 10);
  config.btb_layout = "split";
  config.jump_btb_ways = 1;
  config.ras_entries = 2;
  config.ras_mode = "filter";
  config.ras_filter_entries = 1;
  const BranchRecord call = {{0x1000, 0xef}, {0x2000, true}};
  const BranchRecord ret = {{0x2000, Jalr(0, 1)}, {0x1004, true}};
  for (const char *priority : {"ret", "btb"}) {
    config.ret_priority = priority;
    Predictor model(config);
    model.Update(call);
    model.Update(ret);
    model.Update(call);
    const auto prediction = model.Predict(ret.input.pc);
    Check(prediction.return_conflict && prediction.btb_hit && prediction.taken,
          "complete model arbitrates aliased RET/JAL hits without CLI assistance");
    Check(prediction.ras == (priority[0] == 'r') &&
          prediction.target == (priority[0] == 'r' ? 0x1004u : 0x2000u),
          "complete model owns return priority and target selection");
    if (priority[0] == 'r') {
      model.Update(ret);
      Check(!model.Predict(ret.input.pc).taken,
            "RET hit with empty RAS must suppress JAL fallback");
    }
  }
  config.btb_layout = "unified";
  config.ras_mode = "ideal";
  Predictor ideal(config);
  ideal.Update(call);
  Check(ideal.PredictIdeal(ret.input.pc, true).ras && !ideal.Predict(ret.input.pc).ras,
        "ideal instruction oracle is explicit and separate from PC-only lookup");
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
  RasHints();
  RasBoundedStack();
  RasPredictionAndPollution();
  ReturnTableCapacityAndAliases();
  SplitBtbTrainingAndIsolation();
  SplitBtbLookupArbitration();
  CompletePredictorArbitration();
  std::puts("PASS: 15 branchsim model regression groups");
  return 0;
}
