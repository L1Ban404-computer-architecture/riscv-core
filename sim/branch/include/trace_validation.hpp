#pragma once

#include "insttrace_reader.hpp"

// 在共享文件解码之后，核对指令类型、编码目标和实际跳转结果。
void ValidateTraceRecord(const insttrace::Record &record, std::uint32_t gpr_count);
