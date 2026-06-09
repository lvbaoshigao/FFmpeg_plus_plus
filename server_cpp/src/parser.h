#pragma once
#include <string>
#include <vector>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 解析 ffmpeg 命令字符串
json explainCommand(const std::string& command_str);

// 格式化输出
std::string formatExplanations(const json& result);

} // namespace ffmpegpp
