#pragma once

#include <filesystem>

#include "cache.hpp"
#include "simulation.hpp"

// 每次调用都执行综合和 STA，返回本次报告中的面积、频率及最差 setup/hold slack。
sim::json::object Synthesize(const CacheConfig &config, const std::filesystem::path &work);
