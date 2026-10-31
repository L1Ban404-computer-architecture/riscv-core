#include "simulation.hpp"

// Boost.JSON 的实现仅在本编译单元实例化，不需要额外的链接库。
#include <boost/json/src.hpp>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <stdexcept>

namespace sim {

void RequireKeys(const json::object &object, std::initializer_list<const char *> keys) {
  for (const char *key : keys) {
    if (!object.contains(key)) throw std::invalid_argument(std::string("missing field: ") + key);
  }
  if (object.size() != keys.size()) throw std::invalid_argument("unexpected configuration field");
}

std::uint32_t Uint32(const json::object &object, const char *key) {
  const auto &value = object.at(key);
  std::uint64_t number;
  if (value.is_uint64()) number = value.as_uint64();
  else if (value.is_int64() && value.as_int64() >= 0) number = value.as_int64();
  else throw std::invalid_argument(std::string(key) + " must be an unsigned integer");
  if (number > std::numeric_limits<std::uint32_t>::max())
    throw std::invalid_argument(std::string(key) + " exceeds uint32 range");
  return static_cast<std::uint32_t>(number);
}

double NonnegativeNumber(const json::object &object, const char *key) {
  const auto &value = object.at(key);
  if (!value.is_number()) throw std::invalid_argument(std::string(key) + " must be a number");
  const double number = value.to_number<double>();
  if (!std::isfinite(number) || number < 0)
    throw std::invalid_argument(std::string(key) + " must be finite and nonnegative");
  return number;
}

std::string String(const json::object &object, const char *key) {
  return std::string(object.at(key).as_string());
}

json::value Ratio(std::uint64_t numerator, std::uint64_t denominator) {
  if (denominator == 0) return nullptr;
  return static_cast<double>(numerator) / denominator;
}

int Run(int argc, char **argv, Model model) {
  if (argc != 3) {
    std::fprintf(stderr, "Usage: %s CONFIG.json RESULT.json\n       %s --generate-trace TRACE.bin\n", argv[0], argv[0]);
    return 2;
  }
  try {
    if (std::string(argv[1]) == "--generate-trace") {
      insttrace::EnsureTrace(argv[2]);
      return 0;
    }
    const std::filesystem::path config_path = std::filesystem::absolute(argv[1]);
    std::ifstream input(config_path);
    if (!input) throw std::runtime_error("cannot open config: " + config_path.string());
    const std::string text{std::istreambuf_iterator<char>(input), {}};
    const auto config = json::parse(text).as_object();
    RequireKeys(config, {"trace", "parameters"});
    const auto trace = (config_path.parent_path() / String(config, "trace")).lexically_normal();
    insttrace::Reader reader;
    reader.Open(trace.c_str());
    const std::filesystem::path output_path = std::filesystem::absolute(argv[2]);
    const json::object result = {{"config", config},
                                 {"metrics", model(config.at("parameters").as_object(), reader, output_path)}};

    std::filesystem::create_directories(output_path.parent_path());
    const auto temporary = output_path.string() + ".tmp";
    std::ofstream output(temporary);
    output << json::serialize(result) << '\n';
    output.close();
    if (!output) throw std::runtime_error("cannot write result: " + output_path.string());
    std::filesystem::rename(temporary, output_path);
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s: %s\n", argv[0], error.what());
    return 1;
  }
}
}  // namespace sim
