#pragma once
#include <string>
#include <vector>

namespace ffmpegpp {

// 命令冲突审计
std::vector<std::string> auditCommand(const std::vector<std::string>& cmd);

} // namespace ffmpegpp
