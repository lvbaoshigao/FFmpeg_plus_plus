#pragma once
#include <string>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

struct ToolCheck {
    bool found = false;
    std::string path;
    std::string version;
    std::string error;
};

// 查找 ffmpeg
ToolCheck findFFmpeg();

// 查找 ffprobe
ToolCheck findFFprobe();

// 检测环境
json ensureFFmpeg();

// 安装引导
json getInstallGuide();

// 格式化检测报告
std::string formatCheckReport(const json& check_result);

} // namespace ffmpegpp
