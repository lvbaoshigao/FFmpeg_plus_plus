#pragma once
#include <string>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 检测环境
json ensureFFmpeg();

// 安装引导
json getInstallGuide();

// 获取已解析的 ffmpeg/ffprobe 完整路径（优先使用，避免 PATH 劫持）。
// 按值返回：路径是共享可变状态，返回引用会在锁释放后与 setFFmpegPaths
// 的重新赋值产生数据竞争/悬空引用。
std::string getFFmpegPath();
std::string getFFprobePath();

// 从前端配置覆盖 ffmpeg/ffprobe 路径
void setFFmpegPaths(const std::string& ffmpeg, const std::string& ffprobe);

// 临时目录：桌面端取系统临时目录；Android 无 /tmp，由前端注入
// 应用缓存目录（getTempDir 兜底 TMPDIR）。
void setTempDir(const std::string& dir);
std::string getTempDir();

} // namespace ffmpegpp
