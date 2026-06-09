#pragma once
#include <string>
#include <vector>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 解析编码器名称
std::string resolveEncoder(const std::string& gpu, const std::string& codec_key);

// 构建视频+音频编码参数（input_pix_fmt 用于自动选择输出像素格式）
std::vector<std::string> buildEncodingParams(const json& options, const std::string& input_pix_fmt = "");

// 构建完整转码命令
std::vector<std::string> buildTranscodeCommand(
    const std::string& input_path,
    const std::string& output_path,
    const json& options);

} // namespace ffmpegpp
