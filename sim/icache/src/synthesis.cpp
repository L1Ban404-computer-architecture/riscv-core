#include "synthesis.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <limits>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <vector>

#include "process.hpp"

namespace {

std::string ReadText(const std::filesystem::path &path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("cannot read synthesis report: " + path.string());
  return {std::istreambuf_iterator<char>(input), {}};
}

std::string Trim(const std::string &text) {
  const auto begin = text.find_first_not_of(" \t\r\n");
  return begin == std::string::npos ? "" : text.substr(begin, text.find_last_not_of(" \t\r\n") - begin + 1);
}

double Number(const std::string &text) {
  std::size_t used;
  const double value = std::stod(text, &used);
  if (used != text.size() || !std::isfinite(value))
    throw std::runtime_error("invalid synthesis value: " + text);
  return value;
}

const char *Policy(ReplacementPolicy policy) {
  switch (policy) {
    case ReplacementPolicy::kRoundRobin: return "ICACHE_REPLACEMENT_ROUND_ROBIN";
    case ReplacementPolicy::kTreePlru: return "ICACHE_REPLACEMENT_TREE_PLRU";
  }
  throw std::invalid_argument("unsupported synthesis replacement policy");
}

}  // namespace

sim::json::object Synthesize(const CacheConfig &config, const std::filesystem::path &work) {
  const std::string pdk = std::getenv("PDK") ? std::getenv("PDK") : "nangate45";
  const auto directory = work / "icache_top-1000MHz";
  std::filesystem::create_directories(directory);
  const auto area_report = directory / "synth_stat.txt";
  const auto timing_report = directory / "icache_top.rpt";
  // 不复用旧报告；即使命令成功但未生成新报告，也不能读到上次结果。
  std::filesystem::remove(area_report);
  std::filesystem::remove(timing_report);
  const std::string parameters = "-GBlockBytes=" + std::to_string(config.block_bytes) +
      " -GSetCount=" + std::to_string(config.sets) + " -GWayCount=" + std::to_string(config.ways) +
      " -GReplacementPolicy=" + Policy(config.policy);
  sim::RunCommand({"make", "-C", (sim::CoreDirectory() / "rtl").string(), "perf", "TOP=icache_top",
                   "CLK_PORT_NAME=clk_i", "CLK_FREQ_MHZ=1000", "PDK=" + pdk,
                   "PERF_OUT=" + work.string(), "SLANG_PARAMS=" + parameters}, work / "make.log");

  const std::string area_text = ReadText(area_report);
  std::smatch match;
  const std::regex area_pattern(R"(Chip area for module '\\icache_top':\s*([0-9.eE+-]+))");
  if (!std::regex_search(area_text, match, area_pattern))
    throw std::runtime_error("missing chip area in " + area_report.string());
  const double area = Number(match[1]);
  double frequency = std::numeric_limits<double>::infinity();
  double setup_slack = frequency, hold_slack = frequency;
  std::istringstream report(ReadText(timing_report));
  std::string line;
  while (std::getline(report, line)) {
    if (line.empty() || line.front() != '|') continue;
    std::istringstream row(line);
    std::vector<std::string> cells;
    std::string cell;
    std::getline(row, cell, '|');
    while (std::getline(row, cell, '|')) cells.push_back(Trim(cell));
    if (cells.size() < 8) continue;
    if (cells[2] == "max") {
      setup_slack = std::min(setup_slack, Number(cells[6]));
      if (cells[1] == "core_clock") frequency = std::min(frequency, Number(cells[7]));
    } else if (cells[2] == "min") {
      hold_slack = std::min(hold_slack, Number(cells[6]));
    }
  }
  if (area <= 0 || frequency <= 0 || !std::isfinite(frequency) ||
      !std::isfinite(setup_slack) || !std::isfinite(hold_slack))
    throw std::runtime_error("missing or invalid STA results in " + timing_report.string());
  return {{"synth_area", area}, {"synth_freq_mhz", frequency},
          {"synth_setup_slack_ns", setup_slack}, {"synth_hold_slack_ns", hold_slack}};
}
