#pragma once
#include <string>
#include <vector>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 命令冲突审计
std::vector<std::string> auditCommand(const std::vector<std::string>& cmd);

} // namespace ffmpegpp
