#pragma once

#include <boost/json.hpp>
#include <cstdint>
#include <initializer_list>
#include <string>

#include "insttrace_reader.hpp"

namespace sim {
namespace json = boost::json;

// 模型返回指标；输出路径用于保存综合等附属产物，JSON 发布由 Run 统一负责。
using Model = json::object (*)(const json::object &, insttrace::Reader &, const std::filesystem::path &);
int Run(int argc, char **argv, Model model);
void RequireKeys(const json::object &object, std::initializer_list<const char *> keys);
std::uint32_t Uint32(const json::object &object, const char *key);
double NonnegativeNumber(const json::object &object, const char *key);
std::string String(const json::object &object, const char *key);
// 无样本时返回 null；scale 将比值换算为 MPKI、平均周期等指标。
json::value Ratio(std::uint64_t numerator, std::uint64_t denominator, double scale = 1.0);
}  // namespace sim
