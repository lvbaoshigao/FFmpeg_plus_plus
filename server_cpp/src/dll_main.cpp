#ifdef _WIN32
#include <windows.h>
#endif
#include <string>
#include <thread>
#include <atomic>
#include <cstdlib>
#include <cstring>

#include "ffmpegpp_exports.h"
#include "nlohmann/json.hpp"
#include "json_io.h"
#include "handlers.h"
#include "message_queues.h"

using json = nlohmann::json;
using namespace ffmpegpp;

static const char* SERVER_VERSION = "4.5.0";

static std::thread g_workerThread;
static std::atomic<bool> g_running{false};
static std::atomic<bool> g_cancelFlag{false};
static std::atomic<bool> g_shutdownFlag{false};

static void workerLoop() {
    slog("dll worker: thread started");

    while (!g_shutdownFlag.load()) {
        bool shutdown = false;
        std::string line = popInput(shutdown);
        if (shutdown || g_shutdownFlag.load()) break;
        if (line.empty()) continue;

        json req;
        try {
            req = json::parse(line);
        } catch (...) {
            slog("dll worker: JSON parse error");
            continue;
        }

        std::string action = req.value("action", "");
        slog("dll worker: processing action=%s", action.c_str());

        try {
            if (action == "check_env") {
                handleCheckEnv(req);
            } else if (action == "probe") {
                handleProbe(req);
            } else if (action == "query_ffmpeg_features") {
                handleQueryFeatures(req);
            } else if (action == "transcode") {
                g_cancelFlag.store(false);
                handleTranscode(req, g_cancelFlag);
            } else if (action == "subtitle") {
                g_cancelFlag.store(false);
                handleSubtitle(req, g_cancelFlag);
            } else if (action == "extract_frame") {
                handleExtractFrame(req);
            } else {
                JsonWriter::reply(req.value("id", ""), false, nullptr, "未知 action: " + action);
            }
        } catch (const std::exception& e) {
            slog("dll worker: EXCEPTION: %s", e.what());
            JsonWriter::reply(req.value("id", ""), false, nullptr, std::string("服务器异常: ") + e.what());
        } catch (...) {
            slog("dll worker: UNKNOWN EXCEPTION");
            JsonWriter::reply(req.value("id", ""), false, nullptr, "服务器未知异常");
        }
    }

    slog("dll worker: thread exiting");
}

extern "C" {

FFMPEGPP_API int ffmpegpp_init() {
    if (g_running.load()) return 0;

    slog_init();
    slog("=== DLL INIT v%s ===", SERVER_VERSION);

    JsonWriter::start();

    JsonWriter::send({{"type", "ready"}, {"version", SERVER_VERSION}});

    g_shutdownFlag.store(false);
    g_cancelFlag.store(false);
    g_running.store(true);
    g_workerThread = std::thread(workerLoop);

    slog("dll init: worker thread started");
    return 0;
}

FFMPEGPP_API int ffmpegpp_request(const char* json_utf8) {
    if (!g_running.load() || json_utf8 == nullptr) return -1;

    std::string line(json_utf8);
    slog("dll request: %s", line.substr(0, 200).c_str());

    // cancel/ping/shutdown 内联处理（不进工作线程队列）
    try {
        json req = json::parse(line);
        std::string action = req.value("action", "");

        if (action == "cancel") {
            g_cancelFlag.store(true);
            JsonWriter::reply(req.value("id", ""), true, {{"message", "取消信号已发送"}});
            return 0;
        }
        if (action == "shutdown") {
            g_shutdownFlag.store(true);
            g_cancelFlag.store(true);
            JsonWriter::reply(req.value("id", ""), true, {{"message", "服务器关闭"}});
            wakeInput();
            return 0;
        }
        if (action == "ping") {
            JsonWriter::reply(req.value("id", ""), true, {{"pong", true}});
            return 0;
        }
    } catch (...) {
        return -1;
    }

    pushInput(line);
    return 0;
}

FFMPEGPP_API char* ffmpegpp_poll() {
    std::string line = popOutput();
    if (line.empty()) return nullptr;
    return strdup(line.c_str());
}

FFMPEGPP_API void ffmpegpp_free(char* ptr) {
    if (ptr) free(ptr);
}

FFMPEGPP_API void ffmpegpp_shutdown() {
    if (!g_running.load()) return;

    slog("dll shutdown: starting");
    g_shutdownFlag.store(true);
    g_cancelFlag.store(true);
    wakeInput();

    if (g_workerThread.joinable()) {
        g_workerThread.join();
    }

    JsonWriter::stop();
    g_running.store(false);
    slog("dll shutdown: done");
}

} // extern "C"

#ifdef _WIN32
BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved) {
    (void)hModule;
    (void)lpReserved;
    switch (ul_reason_for_call) {
    case DLL_PROCESS_ATTACH:
    case DLL_THREAD_ATTACH:
    case DLL_THREAD_DETACH:
        break;
    case DLL_PROCESS_DETACH:
        // 不在 DllMain 中 join 线程（持有 loader lock 会导致死锁）
        // 仅发信号让 worker 退出，线程随进程终止自然销毁
        if (g_running.load()) {
            g_shutdownFlag.store(true);
            g_cancelFlag.store(true);
            wakeInput();
            g_workerThread.detach();
            g_running.store(false);
        }
        break;
    }
    return TRUE;
}
#else
__attribute__((destructor))
static void onUnload() {
    if (g_running.load()) {
        g_shutdownFlag.store(true);
        g_cancelFlag.store(true);
        wakeInput();
        g_workerThread.detach();
        g_running.store(false);
    }
}
#endif
