#pragma once
#include <string>
#include <vector>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 命令行分词（支持单/双引号包裹的空格），供自定义命令执行等使用
std::vector<std::string> splitCommand(const std::string& cmd);

// 解析 ffmpeg 命令字符串
json explainCommand(const std::string& command_str);

// 格式化输出
std::string formatExplanations(const json& result);

} // namespace ffmpegpp
