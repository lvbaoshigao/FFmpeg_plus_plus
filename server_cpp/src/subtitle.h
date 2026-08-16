#pragma once
#include <string>
#include <vector>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 构建字幕滤镜字符串
std::string buildSubtitleFilter(const std::string& input_path, const json& subtitle_options);

// 构建完整字幕烧录命令
// input_pix_fmt 非空时复用调用方已探测的源像素格式，避免重复启动 ffprobe
std::vector<std::string> buildSubtitleCommand(
    const std::string& input_path,
    const std::string& output_path,
    const json& subtitle_options,
    const json& video_options = nullptr,
    std::string input_pix_fmt = "");

} // namespace ffmpegpp
