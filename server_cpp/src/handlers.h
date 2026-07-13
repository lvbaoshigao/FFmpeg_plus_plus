#pragma once
#include <string>
#include <vector>
#include <atomic>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 文件日志
void slog_init();
void slog(const char* fmt, ...);

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
void handleTranscode(const json& req, std::atomic<bool>& cancel_flag);
void handleSubtitle(const json& req, std::atomic<bool>& cancel_flag);
void handleExtractFrame(const json& req);
void handleConcat(const json& req, std::atomic<bool>& cancel_flag);
void handleImageSequence(const json& req, std::atomic<bool>& cancel_flag);

void runFFmpegProcess(const std::string& task_id,
                      const std::vector<std::string>& cmd,
                      std::atomic<bool>& cancel_flag,
                      const std::string& output_path);

} // namespace ffmpegpp
