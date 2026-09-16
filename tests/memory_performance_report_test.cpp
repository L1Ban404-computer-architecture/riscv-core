#include <cassert>
#include <cstdio>
#include <sstream>
#include <string>
#ifdef SOC
#include "verilator/performance_report.hpp"
using ysyx_soc::PerformanceCounters;
using ysyx_soc::rtl_report::printPerformanceLog;
#else
#include "rtl/performance_report.hpp"
using mini_soc::rtl::PerformanceCounters;
using mini_soc::rtl::printPerformanceLog;
#endif
static std::string report(const PerformanceCounters &c) {
  auto *f = std::tmpfile();
  assert(f && printPerformanceLog(f, c));
  std::rewind(f);
  std::string text;
  char buf[512];
  while (std::fgets(buf, sizeof(buf), f)) text += buf;
  std::fclose(f);
  return text.substr(text.find(" | IPC"));
}
int main() {
  PerformanceCounters c{};
  assert(report(c).find("imem                  -              -              -") != std::string::npos);
  c.cycle_count = 200;
  c.imem.transaction_count = 4;
  c.imem.request_cycle_sum = (__uint128_t{1} << 110) + 123;
  c.imem.response_cycle_sum = c.imem.request_cycle_sum + 10;
  c.imem.request_stall_cycle_count = 2;
  c.imem.response_stall_cycle_count = 5;
  auto text = report(c);
  std::istringstream row(text.substr(text.find("imem")));
  std::string name, latency, req, rsp;
  row >> name >> latency >> req >> rsp;
  assert(latency == "2.5" && req == "1" && rsp == "2.5");
  assert(text.find("rsp stall(%)") != std::string::npos);
  std::fputs(text.c_str(), stdout);
  c.imem.request_cycle_sum += 20; // No correction for an unfinished request.
  assert(report(c).find("-2.5") != std::string::npos);
}
