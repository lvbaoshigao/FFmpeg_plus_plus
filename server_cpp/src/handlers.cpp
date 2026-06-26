#include "handlers.h"
#include "json_io.h"
#include "subprocess.h"
#include "probe.h"
#include "transcoder.h"
#include "subtitle.h"
#include "installer.h"
#include "audit.h"
#include "ffmpeg_features.h"

#include <windows.h>
#include <iostream>
#include <thread>
#include <chrono>
#include <regex>
#include <algorithm>
#include <sstream>
#include <filesystem>
#include <cstdarg>

namespace ffmpegpp {

// ═══════════════════════════════════════════════
// 日志
// ═══════════════════════════════════════════════

static FILE* g_logFile = nullptr;

void slog_init() {
    char logPath[MAX_PATH];
    const char* appdata = getenv("APPDATA");
    if (appdata) {
        snprintf(logPath, MAX_PATH, "%s\\FFmpeg++\\server_debug.log", appdata);
        char dirPath[MAX_PATH];
        snprintf(dirPath, MAX_PATH, "%s\\FFmpeg++", appdata);
        CreateDirectoryA(dirPath, nullptr);
    } else {
        GetTempPathA(MAX_PATH, logPath);
        strcat(logPath, "FFmpeg++_server_debug.log");
    }
    g_logFile = fopen(logPath, "w");
}

void slog(const char* fmt, ...) {
    if (!g_logFile) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(g_logFile, fmt, args);
    fprintf(g_logFile, "\n");
    fflush(g_logFile);
    va_end(args);
}

// ═══════════════════════════════════════════════
// ProgressParser
// ═══════════════════════════════════════════════

void ProgressParser::feed(const std::string& line) {
    auto m = findRegex(line, R"(time=(\d{2}):(\d{2}):(\d{2}\.\d{2}))");
    if (!m.empty()) {
        current_time = std::stoi(m[1]) * 3600 + std::stoi(m[2]) * 60 + std::stod(m[3]);
    }
    m = findRegex(line, R"(speed=\s*([\d.]+)x)");
    if (!m.empty()) speed = std::stod(m[1]);
    m = findRegex(line, R"(fps=\s*([\d.]+))");
    if (!m.empty()) fps = std::stod(m[1]);
    m = findRegex(line, R"(bitrate=\s*([\d.]+)\s*kbits/s)");
    if (!m.empty()) bitrate = std::stod(m[1]);
    m = findRegex(line, R"(frame=\s*(\d+))");
    if (!m.empty()) frame = std::stoi(m[1]);
}

double ProgressParser::progress() const {
    if (total_duration <= 0) return 0;
    return std::min(current_time / total_duration * 100.0, 100.0);
}

double ProgressParser::remainingSeconds() const {
    if (speed <= 0 || total_duration <= 0) return -1;
    return (total_duration - current_time) / speed;
}

json ProgressParser::stats() const {
    double rem = remainingSeconds();
    return {
        {"progress", std::round(progress() * 10.0) / 10.0},
        {"current_time", fmtTime(current_time)},
        {"total_time", fmtTime(total_duration)},
        {"speed", std::to_string(speed).substr(0, std::to_string(speed).find('.') + 3) + "x"},
        {"fps", std::to_string((int)fps)},
        {"bitrate", std::to_string((int)bitrate) + " kb/s"},
        {"frame", frame},
        {"remaining", rem >= 0 ? fmtTime(rem) : std::string("N/A")},
    };
}

std::string ProgressParser::fmtTime(double seconds) {
    if (seconds < 0) seconds = 0;
    int total = (int)seconds;
    int h = total / 3600, m = (total % 3600) / 60, s = total % 60;
    char buf[16];
    snprintf(buf, sizeof(buf), "%02d:%02d:%02d", h, m, s);
    return buf;
}

std::vector<std::string> ProgressParser::findRegex(const std::string& str, const std::string& pattern) {
    std::vector<std::string> matches;
    try {
        std::regex re(pattern);
        std::smatch m;
        if (std::regex_search(str, m, re)) {
            for (size_t i = 0; i < m.size(); ++i) {
                matches.push_back(m[i].str());
            }
        }
    } catch (...) {}
    return matches;
}

// ═══════════════════════════════════════════════
// 请求处理
// ═══════════════════════════════════════════════

void handleCheckEnv(const json& req) {
    try {
        auto env = ensureFFmpeg();
        json guide;
        if (!env["all_ok"].get<bool>()) {
            guide = getInstallGuide();
            env["install_guide"] = guide;
        }
        JsonWriter::reply(req["id"], true, env);
    } catch (const std::exception& e) {
        JsonWriter::reply(req["id"], false, nullptr, e.what());
    }
}

void handleProbe(const json& req) {
    json params = (req.contains("params") && req["params"].is_object()) ? req["params"] : json::object();
    std::string filepath = params.value("filepath", "");
    try {
        auto result = probeVideo(filepath);
        if (result.success) {
            JsonWriter::reply(req["id"], true, result.info);
        } else {
            JsonWriter::reply(req["id"], false, nullptr, result.error);
        }
    } catch (const std::exception& e) {
        JsonWriter::reply(req["id"], false, nullptr, e.what());
    }
}

void handleQueryFeatures(const json& req) {
    try {
        auto features = queryFFmpegFeatures();
        JsonWriter::reply(req["id"], true, features);
    } catch (const std::exception& e) {
        JsonWriter::reply(req["id"], false, nullptr, e.what());
    }
}

void runFFmpegProcess(const std::string& task_id,
                      const std::vector<std::string>& cmd,
                      std::atomic<bool>& cancel_flag,
                      const std::string& output_path) {
    std::string cmd_str;
    for (auto& a : cmd) { if (!cmd_str.empty()) cmd_str += " "; cmd_str += a; }
    slog("runFFmpeg: cmd=%s", cmd_str.c_str());

    double total_duration = 0;
    for (size_t i = 0; i < cmd.size(); ++i) {
        if (cmd[i] == "-i" && i + 1 < cmd.size()) {
            try {
                auto probe = probeVideo(cmd[i + 1]);
                if (probe.success) {
                    total_duration = probe.info.value("duration", 0.0);
                    slog("runFFmpeg: duration=%.1fs", total_duration);
                }
            } catch (const std::exception& e) {
                slog("runFFmpeg: probe error: %s", e.what());
            }
            break;
        }
    }

    ProgressParser parser;
    parser.total_duration = total_duration;

    JsonWriter::progress(task_id, parser.stats());
    slog("runFFmpeg: starting ffmpeg process...");

    auto start = std::chrono::steady_clock::now();
    std::vector<std::string> stderr_lines;
    int progress_count = 0;
    bool has_real_progress = false;
    double last_sent_progress = -1.0;
    auto last_sent_time = start;

    auto result = Subprocess::runWithProgress(cmd,
        [&](const std::string& line) {
            stderr_lines.push_back(line);
            parser.feed(line);
            progress_count++;
            if (line.find("time=") != std::string::npos) has_real_progress = true;

            auto now = std::chrono::steady_clock::now();
            auto since_last_ms = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_sent_time).count();
            double cur = parser.progress();
            bool should_send = has_real_progress &&
                (since_last_ms >= 1000 || (cur - last_sent_progress) >= 1.0);

            if (should_send) {
                JsonWriter::progress(task_id, parser.stats());
                last_sent_progress = cur;
                last_sent_time = now;
            }
        },
        cancel_flag);

    JsonWriter::progress(task_id, parser.stats());
    slog("runFFmpeg: done, code=%d, stderr=%zu, progress_count=%d", result.exit_code, stderr_lines.size(), progress_count);

    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start).count() / 1000.0;

    if (cancel_flag.load()) {
        JsonWriter::reply(task_id, false, nullptr, "任务已取消");
        return;
    }

    if (result.exit_code == 0) {
        JsonWriter::progress(task_id, {{"progress", 100.0}, {"speed", "0.00x"}, {"remaining", "00:00:00"}});

        int64_t out_size = 0;
        if (!output_path.empty()) {
            try { out_size = std::filesystem::file_size(output_path); } catch (...) {}
        }
        JsonWriter::reply(task_id, true, {
            {"output_path", output_path},
            {"output_size", out_size},
            {"duration", elapsed},
            {"command", cmd},
        });
    } else {
        std::string error_msg;
        size_t start_idx = stderr_lines.size() > 5 ? stderr_lines.size() - 5 : 0;
        for (size_t i = start_idx; i < stderr_lines.size(); ++i) {
            if (!error_msg.empty()) error_msg += "; ";
            error_msg += stderr_lines[i];
        }
        if (error_msg.empty()) error_msg = "退出码 " + std::to_string(result.exit_code);

        json log_lines = json::array();
        size_t log_start = stderr_lines.size() > 100 ? stderr_lines.size() - 100 : 0;
        for (size_t i = log_start; i < stderr_lines.size(); ++i) {
            log_lines.push_back(stderr_lines[i]);
        }

        JsonWriter::reply(task_id, false, {{"log_lines", log_lines}, {"command", cmd}}, error_msg);
    }
}

void handleTranscode(const json& req, std::atomic<bool>& cancel_flag) {
    json params = (req.contains("params") && req["params"].is_object()) ? req["params"] : json::object();
    std::string input = params.value("input", "");
    std::string output = params.value("output", "");
    json options = params.value("options", json::object());

    std::string input_pix_fmt;
    try {
        auto probe = probeVideo(input);
        if (probe.success) {
            input_pix_fmt = probe.info.value("pix_fmt", "");
        }
    } catch (...) {}

    std::vector<std::string> cmd;
    try {
        cmd = buildTranscodeCommand(input, output, options);
    } catch (const std::exception& e) {
        JsonWriter::reply(req["id"], false, nullptr, std::string("命令构建失败: ") + e.what());
        return;
    }

    std::vector<std::string> warnings;
    if (input_pix_fmt.find("10") != std::string::npos) {
        std::string gpu = options.value("gpu", "CPU");
        std::string video_codec = options.value("video_codec", "h264");
        bool has10bitPixFmt = false;
        for (const auto& arg : cmd) {
            if (arg.find("10le") != std::string::npos || arg.find("p010") != std::string::npos) {
                has10bitPixFmt = true;
                break;
            }
        }
        if (!has10bitPixFmt) {
            if (video_codec == "h264") {
                warnings.push_back("H.264 不支持 10-bit，画质已降级为 8-bit。如需保留 10-bit，请选择 H.265 编码");
            } else {
                warnings.push_back("源文件是 10-bit (" + input_pix_fmt + ")，但 " + gpu + " " + video_codec + " 编码器不支持 10-bit 输出，画质将降级为 8-bit");
            }
        }
    }

    auto cmd_warnings = auditCommand(cmd);
    warnings.insert(warnings.end(), cmd_warnings.begin(), cmd_warnings.end());

    if (!warnings.empty()) {
        JsonWriter::audit(req["id"], warnings);
    }

    runFFmpegProcess(req["id"], cmd, cancel_flag, output);
}

void handleSubtitle(const json& req, std::atomic<bool>& cancel_flag) {
    json params = (req.contains("params") && req["params"].is_object()) ? req["params"] : json::object();
    std::string input = params.value("input", "");
    std::string output = params.value("output", "");
    json sub_opts = params.value("subtitle_options", json::object());
    json vid_opts = params.contains("video_options") ? params["video_options"] : nullptr;

    std::string input_pix_fmt;
    try {
        auto probe = probeVideo(input);
        if (probe.success) {
            input_pix_fmt = probe.info.value("pix_fmt", "");
        }
    } catch (...) {}

    std::vector<std::string> cmd;
    try {
        cmd = buildSubtitleCommand(input, output, sub_opts, vid_opts);
    } catch (const std::exception& e) {
        JsonWriter::reply(req["id"], false, nullptr, std::string("命令构建失败: ") + e.what());
        return;
    }

    std::vector<std::string> warnings;
    if (input_pix_fmt.find("10") != std::string::npos) {
        std::string gpu = vid_opts.is_object() ? vid_opts.value("gpu", "CPU") : "CPU";
        std::string video_codec = vid_opts.is_object() ? vid_opts.value("video_codec", "h264") : "h264";
        bool has10bitPixFmt = false;
        for (const auto& arg : cmd) {
            if (arg.find("10le") != std::string::npos || arg.find("p010") != std::string::npos) {
                has10bitPixFmt = true;
                break;
            }
        }
        if (!has10bitPixFmt) {
            if (video_codec == "h264") {
                warnings.push_back("H.264 不支持 10-bit，画质已降级为 8-bit。如需保留 10-bit，请选择 H.265 编码");
            } else {
                warnings.push_back("源文件是 10-bit (" + input_pix_fmt + ")，但 " + gpu + " " + video_codec + " 编码器不支持 10-bit 输出，画质将降级为 8-bit");
            }
        }
    }

    auto cmd_warnings = auditCommand(cmd);
    warnings.insert(warnings.end(), cmd_warnings.begin(), cmd_warnings.end());

    if (!warnings.empty()) {
        JsonWriter::audit(req["id"], warnings);
    }

    runFFmpegProcess(req["id"], cmd, cancel_flag, output);
}

void handleExtractFrame(const json& req) {
    json params = (req.contains("params") && req["params"].is_object()) ? req["params"] : json::object();
    std::string input = params.value("input", "");
    std::string output = params.value("output", "");
    double time = params.value("time", 0.0);

    std::vector<std::string> cmd = {
        "ffmpeg", "-ss", std::to_string(time),
        "-i", input, "-vframes", "1", "-q:v", "2", "-y", output
    };

    slog("extractFrame: time=%.3f input=%s output=%s", time, input.c_str(), output.c_str());

    auto result = Subprocess::run(cmd, 30);
    if (result.exit_code == 0) {
        int64_t out_size = 0;
        try { out_size = std::filesystem::file_size(output); } catch (...) {}
        JsonWriter::reply(req["id"], true, {
            {"output_path", output},
            {"output_size", out_size},
        });
    } else {
        std::string err = result.stderr_output.empty() ? "退出码 " + std::to_string(result.exit_code) : result.stderr_output.substr(0, 300);
        JsonWriter::reply(req["id"], false, nullptr, err);
    }
}

} // namespace ffmpegpp
