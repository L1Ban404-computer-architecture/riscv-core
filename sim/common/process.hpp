#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace sim {
std::filesystem::path CoreDirectory();
// 直接传递 argv，不经 shell 解释；stdout/stderr 保存到 log，失败抛出异常。
void RunCommand(const std::vector<std::string> &arguments, const std::filesystem::path &log);
}  // namespace sim
