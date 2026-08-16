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

// 获取已解析的 ffmpeg/ffprobe 完整路径（优先使用，避免 PATH 劫持）
const std::string& getFFmpegPath();
const std::string& getFFprobePath();

// 从前端配置覆盖 ffmpeg/ffprobe 路径
void setFFmpegPaths(const std::string& ffmpeg, const std::string& ffprobe);

// 临时目录：桌面端取系统临时目录；Android 无 /tmp，由前端注入
// 应用缓存目录（getTempDir 兜底 TMPDIR）。
void setTempDir(const std::string& dir);
std::string getTempDir();

} // namespace ffmpegpp
