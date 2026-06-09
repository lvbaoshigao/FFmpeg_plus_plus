#include <windows.h>
#include <process.h>
#include <iostream>
#include <string>
#include <thread>
#include <atomic>
#include <chrono>
#include <queue>
#include <mutex>
#include <condition_variable>
#include <regex>
#include <algorithm>
#include <sstream>

#include "nlohmann/json.hpp"
#include "json_io.h"
#include "subprocess.h"
#include "probe.h"
#include "transcoder.h"
#include "subtitle.h"
#include "installer.h"
#include "parser.h"
#include "audit.h"
#include "ffmpeg_features.h"
#include "constants.h"

using json = nlohmann::json;
using namespace ffmpegpp;

static const char* SERVER_VERSION = "2.0.0";

// 文件日志（写到 exe 同目录的 server_debug.log）
static FILE* g_logFile = nullptr;
static void slog(const char* fmt, ...) {
    if (!g_logFile) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(g_logFile, fmt, args);
    fprintf(g_logFile, "\n");
    fflush(g_logFile);
    va_end(args);
}

// ═══════════════════════════════════════════════
// 进度解析器
// ═══════════════════════════════════════════════

class ProgressParser {
public:
    double total_duration = 0;
    double current_time = 0;
    double speed = 0;
    double fps = 0;
    double bitrate = 0;
    int frame = 0;

    void feed(const std::string& line) {
        // time=00:05:23.45
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

    double progress() const {
        if (total_duration <= 0) return 0;
        return std::min(current_time / total_duration * 100.0, 100.0);
    }

    double remainingSeconds() const {
        if (speed <= 0 || total_duration <= 0) return -1;
        return (total_duration - current_time) / speed;
    }

    json stats() const {
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

private:
    static std::string fmtTime(double seconds) {
        if (seconds < 0) seconds = 0;
        int total = (int)seconds;
        int h = total / 3600, m = (total % 3600) / 60, s = total % 60;
        char buf[16];
        snprintf(buf, sizeof(buf), "%02d:%02d:%02d", h, m, s);
        return buf;
    }

    static std::vector<std::string> findRegex(const std::string& str, const std::string& pattern) {
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
};

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
    // 打印完整命令
    std::string cmd_str;
    for (auto& a : cmd) { if (!cmd_str.empty()) cmd_str += " "; cmd_str += a; }
    slog("runFFmpeg: cmd=%s", cmd_str.c_str());

    // 获取视频时长
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

    // 初始进度
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

            // 有真实进度后，每秒发一次或进度变化 >=1% 时发送
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

    // 最终进度
    JsonWriter::progress(task_id, parser.stats());
    slog("runFFmpeg: done, code=%d, stderr=%zu, progress_count=%d", result.exit_code, stderr_lines.size(), progress_count);

    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start).count() / 1000.0;

    if (cancel_flag.load()) {
        JsonWriter::reply(task_id, false, nullptr, "任务已取消");
        return;
    }

    if (result.exit_code == 0) {
        // 最终 100% 进度
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
        // 取最后 5 行 stderr
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

    // 探测源像素格式，检查 10-bit 兼容性
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

    // 检查 10-bit 兼容性并生成警告
    std::vector<std::string> warnings;
    if (input_pix_fmt.find("10") != std::string::npos) {
        std::string gpu = options.value("gpu", "CPU");
        std::string video_codec = options.value("video_codec", "h264");
        // 检查命令中是否包含正确的 10-bit 像素格式
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

    // 探测源像素格式，检查 10-bit 兼容性
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

    // 检查 10-bit 兼容性并生成警告
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

// ═══════════════════════════════════════════════
// 主入口
// ═══════════════════════════════════════════════

// CLI 调试模式：直接测试命令构建和执行
void cliDebug() {
    fprintf(stderr, "=== FFmpeg++ CLI Debug Mode ===\n");
    fprintf(stderr, "Commands: probe <file> | transcode <in> <out> [opts] | subtitle <in> <out> <sub> [opts] | check | features | quit\n");
    fprintf(stderr, "Examples:\n");
    fprintf(stderr, "  probe G:/cache/tqzz/tqzz.mkv\n");
    fprintf(stderr, "  subtitle G:/cache/tqzz/tqzz.mkv G:/cache/tqzz/out.mp4 G:/cache/tqzz/tqzzz.ass gpu=NVIDIA codec=h265\n");
    fprintf(stderr, "  transcode G:/cache/tqzz/tqzz.mkv G:/cache/tqzz/out.mp4 gpu=NVIDIA codec=h265 bitrate=8000\n");
    fprintf(stderr, "\n");

    std::string line;
    while (true) {
        fprintf(stderr, "> ");
        fflush(stderr);
        if (!std::getline(std::cin, line)) break;
        if (line.empty()) continue;
        if (line == "quit" || line == "exit") break;

        // 解析命令
        std::istringstream iss(line);
        std::string cmd;
        iss >> cmd;

        if (cmd == "check") {
            auto env = ensureFFmpeg();
            fprintf(stderr, "%s\n", formatCheckReport(env).c_str());
        }
        else if (cmd == "probe") {
            std::string filepath;
            iss >> filepath;
            fprintf(stderr, "Probing: %s\n", filepath.c_str());
            auto result = probeVideo(filepath);
            if (result.success) {
                fprintf(stderr, "  Codec: %s\n", result.info.value("codec", "?").c_str());
                fprintf(stderr, "  Resolution: %s\n", result.info.value("resolution", "?").c_str());
                fprintf(stderr, "  PixFmt: %s\n", result.info.value("pix_fmt", "?").c_str());
                fprintf(stderr, "  Duration: %.1fs\n", result.info.value("duration", 0.0));
                fprintf(stderr, "  Audio: %s %dch\n", result.info.value("audio_codec", "?").c_str(), result.info.value("audio_channels", 0));
            } else {
                fprintf(stderr, "  Error: %s\n", result.error.c_str());
            }
        }
        else if (cmd == "transcode") {
            std::string in, out;
            iss >> in >> out;
            json opts = {{"video_codec", "h264"}, {"gpu", "CPU"}, {"video_bitrate", 2000}, {"audio_codec", "aac"}, {"audio_bitrate", 128}};
            // 解析 key=value 参数
            std::string kv;
            while (iss >> kv) {
                auto eq = kv.find('=');
                if (eq != std::string::npos) {
                    std::string k = kv.substr(0, eq), v = kv.substr(eq + 1);
                    if (k == "codec") opts["video_codec"] = v;
                    else if (k == "gpu") opts["gpu"] = v;
                    else if (k == "bitrate") opts["video_bitrate"] = std::stoi(v);
                    else if (k == "preset") opts["preset"] = v;
                    else if (k == "crf") opts["crf"] = std::stoi(v);
                }
            }
            try {
                auto cmd = buildTranscodeCommand(in, out, opts);
                fprintf(stderr, "Command: ");
                for (auto& a : cmd) fprintf(stderr, "%s ", a.c_str());
                fprintf(stderr, "\n");
                // 执行
                std::atomic<bool> cancel{false};
                runFFmpegProcess("cli", cmd, cancel, out);
            } catch (const std::exception& e) {
                fprintf(stderr, "Error: %s\n", e.what());
            }
        }
        else if (cmd == "subtitle") {
            std::string in, out, sub;
            iss >> in >> out >> sub;
            json subOpts = {{"source", "external"}, {"subtitle_file", sub}};
            json vidOpts = {{"video_codec", "h265"}, {"gpu", "NVIDIA"}, {"video_bitrate", 8000}, {"audio_codec", "aac"}, {"audio_bitrate", 192}};
            std::string kv;
            while (iss >> kv) {
                auto eq = kv.find('=');
                if (eq != std::string::npos) {
                    std::string k = kv.substr(0, eq), v = kv.substr(eq + 1);
                    if (k == "codec") vidOpts["video_codec"] = v;
                    else if (k == "gpu") vidOpts["gpu"] = v;
                    else if (k == "bitrate") vidOpts["video_bitrate"] = std::stoi(v);
                    else if (k == "preset") vidOpts["preset"] = v;
                    else if (k == "crf") vidOpts["crf"] = std::stoi(v);
                    else if (k == "font") subOpts["style"]["font_name"] = v;
                    else if (k == "fontsize") subOpts["style"]["font_size"] = std::stoi(v);
                    else if (k == "color") subOpts["style"]["font_color"] = v;
                }
            }
            try {
                auto cmd = buildSubtitleCommand(in, out, subOpts, vidOpts);
                fprintf(stderr, "Command: ");
                for (auto& a : cmd) fprintf(stderr, "%s ", a.c_str());
                fprintf(stderr, "\n");
                std::atomic<bool> cancel{false};
                runFFmpegProcess("cli", cmd, cancel, out);
            } catch (const std::exception& e) {
                fprintf(stderr, "Error: %s\n", e.what());
            }
        }
        else if (cmd == "features") {
            auto f = queryFFmpegFeatures();
            for (auto& [k, v] : f.items()) {
                if (v.is_array()) fprintf(stderr, "  %s: %d items\n", k.c_str(), (int)v.size());
            }
        }
        else {
            fprintf(stderr, "Unknown command: %s\n", cmd.c_str());
        }
    }
}

int main(int argc, char* argv[]) {
    // CLI 调试模式
    if (argc > 1 && std::string(argv[1]) == "--cli") {
        cliDebug();
        return 0;
    }

    // 打开日志文件
    char logPath[MAX_PATH];
    GetModuleFileNameA(nullptr, logPath, MAX_PATH);
    // 替换 exe 名为 server_debug.log
    char* lastSlash = strrchr(logPath, '\\');
    if (lastSlash) strcpy(lastSlash + 1, "server_debug.log");
    g_logFile = fopen(logPath, "w");

    slog("=== SERVER START v%s ===", SERVER_VERSION);
    slog("exe: %s", logPath);

    // 隐藏控制台窗口（Flutter 通过管道通信，不需要可见窗口）
    HWND hwnd = GetConsoleWindow();
    slog("console hwnd: %p", hwnd);
    if (hwnd) ShowWindow(hwnd, SW_HIDE);

    // 设置 stdin/stdout 为 UTF-8
    SetConsoleOutputCP(65001);
    SetConsoleCP(65001);

    // 检查句柄
    HANDLE hIn = GetStdHandle(STD_INPUT_HANDLE);
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE hErr = GetStdHandle(STD_ERROR_HANDLE);
    slog("stdin handle: %p (invalid=%d)", hIn, hIn == INVALID_HANDLE_VALUE);
    slog("stdout handle: %p (invalid=%d)", hOut, hOut == INVALID_HANDLE_VALUE);
    slog("stderr handle: %p (invalid=%d)", hErr, hErr == INVALID_HANDLE_VALUE);

    // 发送 ready
    // 启动异步 stdout 写入线程
    JsonWriter::start();
    slog("sending ready...");
    JsonWriter::send({{"type", "ready"}, {"version", SERVER_VERSION}});
    slog("ready sent");

    std::atomic<bool> cancel_flag{false};

    // stdin 读取线程 + 请求队列
    std::queue<json> req_queue;
    std::mutex queue_mutex;
    std::condition_variable queue_cv;
    std::atomic<bool> shutdown_flag{false};

    slog("starting stdin_reader thread...");
    std::thread stdin_reader([&]() {
        slog("stdin_reader: thread started");
        json req;
        while (!shutdown_flag.load() && JsonReader::readLine(req)) {
            std::string action = req.value("action", "");
            slog("stdin_reader: got action=%s", action.c_str());

            if (action == "cancel") {
                cancel_flag.store(true);
                JsonWriter::reply(req.value("id", ""), true, {{"message", "取消信号已发送"}});
            } else if (action == "shutdown") {
                shutdown_flag.store(true);
                cancel_flag.store(true);
                JsonWriter::reply(req.value("id", ""), true, {{"message", "服务器关闭"}});
                queue_cv.notify_all();
                return;
            } else if (action == "ping") {
                JsonWriter::reply(req.value("id", ""), true, {{"pong", true}});
            } else {
                std::lock_guard<std::mutex> lock(queue_mutex);
                req_queue.push(req);
                queue_cv.notify_one();
            }
        }
    });

    // 主循环：从队列取请求处理
    while (!shutdown_flag.load()) {
        json req;
        {
            std::unique_lock<std::mutex> lock(queue_mutex);
            queue_cv.wait_for(lock, std::chrono::milliseconds(500), [&]() {
                return !req_queue.empty() || shutdown_flag.load();
            });
            if (req_queue.empty()) continue;
            req = req_queue.front();
            req_queue.pop();
        }

        std::string action = req.value("action", "");
        slog("main: processing action=%s", action.c_str());

        try {
            if (action == "check_env") {
                handleCheckEnv(req);
            } else if (action == "probe") {
                handleProbe(req);
            } else if (action == "query_ffmpeg_features") {
                handleQueryFeatures(req);
            } else if (action == "transcode") {
                cancel_flag.store(false);
                slog("main: calling handleTranscode");
                handleTranscode(req, cancel_flag);
                slog("main: handleTranscode done");
            } else if (action == "subtitle") {
                cancel_flag.store(false);
                slog("main: calling handleSubtitle");
                handleSubtitle(req, cancel_flag);
                slog("main: handleSubtitle done");
            } else {
                JsonWriter::reply(req.value("id", ""), false, nullptr, "未知 action: " + action);
            }
        } catch (const std::exception& e) {
            slog("main: EXCEPTION: %s", e.what());
            JsonWriter::reply(req.value("id", ""), false, nullptr, std::string("服务器异常: ") + e.what());
        } catch (...) {
            slog("main: UNKNOWN EXCEPTION");
            JsonWriter::reply(req.value("id", ""), false, nullptr, "服务器未知异常");
        }
    }

    cancel_flag.store(true);
    stdin_reader.join();
    JsonWriter::stop();
    return 0;
}
