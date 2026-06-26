#include <windows.h>
#include <iostream>
#include <string>
#include <thread>
#include <atomic>
#include <chrono>
#include <queue>
#include <mutex>
#include <condition_variable>
#include <sstream>

#include "nlohmann/json.hpp"
#include "json_io.h"
#include "handlers.h"
#include "probe.h"
#include "transcoder.h"
#include "subtitle.h"
#include "installer.h"
#include "ffmpeg_features.h"

using json = nlohmann::json;
using namespace ffmpegpp;

static const char* SERVER_VERSION = "3.0.0";

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
                auto tcmd = buildTranscodeCommand(in, out, opts);
                fprintf(stderr, "Command: ");
                for (auto& a : tcmd) fprintf(stderr, "%s ", a.c_str());
                fprintf(stderr, "\n");
                std::atomic<bool> cancel{false};
                runFFmpegProcess("cli", tcmd, cancel, out);
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
                auto scmd = buildSubtitleCommand(in, out, subOpts, vidOpts);
                fprintf(stderr, "Command: ");
                for (auto& a : scmd) fprintf(stderr, "%s ", a.c_str());
                fprintf(stderr, "\n");
                std::atomic<bool> cancel{false};
                runFFmpegProcess("cli", scmd, cancel, out);
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
    if (argc > 1 && std::string(argv[1]) == "--cli") {
        cliDebug();
        return 0;
    }

    slog_init();
    slog("=== SERVER START v%s ===", SERVER_VERSION);

    slog("console hwnd: %p (ShowWindow skipped)", GetConsoleWindow());

    SetConsoleOutputCP(65001);
    SetConsoleCP(65001);

    HANDLE hIn = GetStdHandle(STD_INPUT_HANDLE);
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE hErr = GetStdHandle(STD_ERROR_HANDLE);
    slog("stdin handle: %p (invalid=%d)", hIn, hIn == INVALID_HANDLE_VALUE);
    slog("stdout handle: %p (invalid=%d)", hOut, hOut == INVALID_HANDLE_VALUE);
    slog("stderr handle: %p (invalid=%d)", hErr, hErr == INVALID_HANDLE_VALUE);

    JsonWriter::start();
    slog("sending ready...");
    JsonWriter::send({{"type", "ready"}, {"version", SERVER_VERSION}});
    slog("ready sent");

    std::atomic<bool> cancel_flag{false};

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
            } else if (action == "extract_frame") {
                handleExtractFrame(req);
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
