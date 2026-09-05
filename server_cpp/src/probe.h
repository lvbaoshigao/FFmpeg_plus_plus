#pragma once
#include <string>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

struct ProbeResult {
    bool success = false;
    json info;       // 结构化信息
    std::string error;
};

// 探测视频文件信息
ProbeResult probeVideo(const std::string& filepath);

// 探测字幕文件信息
ProbeResult probeSubtitle(const std::string& filepath);

// 通用探测（返回原始 ffprobe JSON）
ProbeResult probeFile(const std::string& filepath);

} // namespace ffmpegpp
