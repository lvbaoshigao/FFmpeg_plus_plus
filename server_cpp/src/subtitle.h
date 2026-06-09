#pragma once
#include <string>
#include <vector>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 构建字幕滤镜字符串
std::string buildSubtitleFilter(const std::string& input_path, const json& subtitle_options);

// 构建完整字幕烧录命令
std::vector<std::string> buildSubtitleCommand(
    const std::string& input_path,
    const std::string& output_path,
    const json& subtitle_options,
    const json& video_options = nullptr);

} // namespace ffmpegpp
