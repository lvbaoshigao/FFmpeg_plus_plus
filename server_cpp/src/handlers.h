#pragma once
#include <string>
#include <vector>
#include <atomic>
#include <functional>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 取消判定回调：返回 true 表示当前任务已被取消。
// 取代旧的全局 std::atomic<bool>& cancel_flag（全局标志会在任务启动时被清零，
// 导致精确取消失效或误作用于其它任务，见 M-5）。
using CancelCheck = std::function<bool()>;

// 文件日志
void slog_init();
void slog(const char* fmt, ...);
void slog_cleanup();

// 进度解析器
class ProgressParser {
public:
    double total_duration = 0;
    double current_time = 0;
    double speed = 0;
    double fps = 0;
    double bitrate = 0;
    int frame = 0;

    void feed(const std::string& line);
    double progress() const;
    double remainingSeconds() const;
    json stats() const;

private:
    static std::string fmtTime(double seconds);
    static std::vector<std::string> findRegex(const std::string& str, const std::string& pattern);
};

// 请求处理
void handleCheckEnv(const json& req);
void handleProbe(const json& req);
void handleQueryFeatures(const json& req);
void handleTranscode(const json& req, const CancelCheck& isCancelled);
void handleSubtitle(const json& req, const CancelCheck& isCancelled);
void handleExtractFrame(const json& req, const CancelCheck& isCancelled);
void handleConcat(const json& req, const CancelCheck& isCancelled);
void handleImageSequence(const json& req, const CancelCheck& isCancelled);
void handleCustomCommand(const json& req, const CancelCheck& isCancelled);

// FPPX 配置文件（新版 v2 + 旧版迁移），纯文件解析无 ffmpeg 依赖
void handleFppxImport(const json& req);       // 自动路由（按文件头判别新旧格式）
void handleFppx2Import(const json& req);
void handleFppx2Export(const json& req);
void handleFppxLegacyImport(const json& req);
void handleFppxLegacyExport(const json& req);

void runFFmpegProcess(const std::string& task_id,
                      const std::vector<std::string>& cmd,
                      const CancelCheck& isCancelled,
                      const std::string& output_path);

} // namespace ffmpegpp
