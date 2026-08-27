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
#include "installer.h"
#include "message_queues.h"
#include <set>
#include <mutex>
#include <vector>
#include <functional>

using json = nlohmann::json;
using namespace ffmpegpp;

static const char* SERVER_VERSION = "5.2.0";

static std::thread g_workerThread;
static std::atomic<bool> g_running{false};
static std::atomic<bool> g_cancelFlag{false};
static std::atomic<bool> g_shutdownFlag{false};

// 已被前端取消、尚未被 worker 消费的任务 id 集合（批量取消用）
static std::set<std::string> g_cancelledTaskIds;
static std::mutex g_cancelMutex;

// 一次性 init 保护：并发 init 会对 joinable 的 g_workerThread 重新赋值导致 std::terminate
static std::mutex g_initMutex;

// probe / check_env / query_ffmpeg_features 跑在辅助线程上；追踪并统一 join，
// 避免库卸载（dlclose / DLL_PROCESS_DETACH）时这些线程仍在库代码内执行而崩溃。
static std::mutex g_auxThreadsMutex;
static std::vector<std::thread> g_auxThreads;

static void spawnAuxThread(std::function<void()> fn) {
    std::lock_guard<std::mutex> lock(g_auxThreadsMutex);
    g_auxThreads.emplace_back(std::move(fn));
}

static void joinAuxThreads() {
    std::vector<std::thread> threads;
    {
        std::lock_guard<std::mutex> lock(g_auxThreadsMutex);
        threads.swap(g_auxThreads);
    }
    for (auto& t : threads) {
        if (t.joinable()) t.join();
    }
}

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
            // 队列中已被取消的任务直接跳过（cancel 携带 task_ids 时），
            // 避免「停止所有」后后端仍继续执行排队任务
            {
                std::lock_guard<std::mutex> lock(g_cancelMutex);
                auto it = g_cancelledTaskIds.find(req.value("id", ""));
                if (it != g_cancelledTaskIds.end()) {
                    g_cancelledTaskIds.erase(it);
                    JsonWriter::reply(req.value("id", ""), false, nullptr, "任务已取消");
                    continue;
                }
            }
            if (action == "transcode") {
                g_cancelFlag.store(false);
                handleTranscode(req, g_cancelFlag);
            } else if (action == "subtitle") {
                g_cancelFlag.store(false);
                handleSubtitle(req, g_cancelFlag);
            } else if (action == "extract_frame") {
                handleExtractFrame(req);
            } else if (action == "concat") {
                g_cancelFlag.store(false);
                handleConcat(req, g_cancelFlag);
            } else if (action == "image_sequence") {
                g_cancelFlag.store(false);
                handleImageSequence(req, g_cancelFlag);
            } else if (action == "custom_command") {
                g_cancelFlag.store(false);
                handleCustomCommand(req, g_cancelFlag);
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
    std::lock_guard<std::mutex> lock(g_initMutex);
    if (g_running.load()) return 0;

    slog_init();
    slog("=== DLL INIT v%s ===", SERVER_VERSION);

    JsonWriter::start();

    JsonWriter::send({{"type", "ready"}, {"version", SERVER_VERSION}});

    g_shutdownFlag.store(false);
    g_cancelFlag.store(false);
    resetInputWake();  // 清掉历史 wake 标志，避免重初始化后 worker 立即退出
    
    // 先创建线程，再设置运行标志（避免 workerLoop 在线程对象完全赋值前就开始运行）
    g_workerThread = std::thread(workerLoop);
    g_running.store(true);

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
            // 支持批量取消：携带 task_ids 时，worker 处理这些任务前会跳过
            auto params = req.value("params", json::object());
            if (params.contains("task_ids") && params["task_ids"].is_array()) {
                std::lock_guard<std::mutex> lock(g_cancelMutex);
                for (auto& tid : params["task_ids"]) {
                    if (tid.is_string()) g_cancelledTaskIds.insert(tid.get<std::string>());
                }
            }
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
        if (action == "set_paths") {
            auto params = req.value("params", json::object());
            setFFmpegPaths(params.value("ffmpeg", ""), params.value("ffprobe", ""));
            // Android 无 /tmp：前端注入应用缓存目录作为临时目录
            auto tempDir = params.value("temp_dir", "");
            if (!tempDir.empty()) setTempDir(tempDir);
            JsonWriter::reply(req.value("id", ""), true, {{"message", "paths updated"}});
            return 0;
        }
        if (action == "probe" || action == "check_env" || action == "query_ffmpeg_features") {
            // 捕获 lambda 内的异常，避免线程内未捕获导致程序终止
            try {
                spawnAuxThread([req]() {
                    try {
                        if (req.value("action", "") == "probe") handleProbe(req);
                        else if (req.value("action", "") == "check_env") handleCheckEnv(req);
                        else handleQueryFeatures(req);
                    } catch (const std::exception& e) {
                        slog("aux thread exception: %s", e.what());
                        JsonWriter::reply(req.value("id", ""), false, nullptr, std::string("服务器异常: ") + e.what());
                    } catch (...) {
                        slog("aux thread: unknown exception");
                        JsonWriter::reply(req.value("id", ""), false, nullptr, "服务器未知异常");
                    }
                });
            } catch (const std::exception& e) {
                slog("spawnAuxThread failed: %s", e.what());
                JsonWriter::reply(req.value("id", ""), false, nullptr, std::string("线程创建失败: ") + e.what());
                return -1;
            }
            return 0;
        }
    } catch (const json::parse_error& e) {
        slog("dll request: JSON parse error: %s", e.what());
        JsonWriter::reply("unknown", false, nullptr, std::string("JSON 解析错误: ") + e.what());
        return -1;
    } catch (const std::exception& e) {
        slog("dll request: exception: %s", e.what());
        JsonWriter::reply("unknown", false, nullptr, std::string("请求处理异常: ") + e.what());
        return -1;
    } catch (...) {
        slog("dll request: unknown exception");
        JsonWriter::reply("unknown", false, nullptr, "未知异常");
        return -1;
    }

    pushInput(line);
    return 0;
}

FFMPEGPP_API char* ffmpegpp_poll() {
    std::string line = popOutput();
    if (line.empty()) return nullptr;
    // strdup 分配的新内存由调用方负责释放（通过 ffmpegpp_free）
    char* result = strdup(line.c_str());
    if (!result) {
        // 内存分配失败时记录错误（避免静默失败）
        slog("ffmpegpp_poll: strdup failed, line length=%zu", line.size());
    }
    return result;
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

    // 先等 probe/check_env/query_features 辅助线程退出，再停止输出与线程
    joinAuxThreads();

    if (g_workerThread.joinable()) {
        g_workerThread.join();
    }

    JsonWriter::stop();
    g_running.store(false);
    slog("dll shutdown: done");
    slog_cleanup();
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
        joinAuxThreads();
        if (g_workerThread.joinable()) g_workerThread.join();
        g_running.store(false);
    }
}
#endif
