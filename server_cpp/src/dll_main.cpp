#ifdef _WIN32
#include <windows.h>
#endif
#include <string>
#include <thread>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <map>

#include "ffmpegpp_exports.h"
#include "nlohmann/json.hpp"
#include "json_io.h"
#include "handlers.h"
#include "subprocess.h"
#include "installer.h"
#include "message_queues.h"
#include <set>
#include <mutex>
#include <vector>
#include <memory>
#include <functional>
#include <condition_variable>

using json = nlohmann::json;
using namespace ffmpegpp;

static const char* SERVER_VERSION = "5.30.51";

static std::thread g_workerThread;
static std::atomic<bool> g_running{false};
static std::atomic<bool> g_cancelFlag{false};
static std::atomic<bool> g_shutdownFlag{false};

// 已被前端取消、尚未被 worker 消费的任务 id 集合（批量取消用）
static std::set<std::string> g_cancelledTaskIds;
static std::mutex g_cancelMutex;

// Expiry index keeps cleanup work proportional to expired records.
using CancelExpiryMap = std::multimap<std::chrono::steady_clock::time_point, std::string>;
static CancelExpiryMap g_cancelledTaskExpirations;
static std::map<std::string, CancelExpiryMap::iterator> g_cancelledTaskExpiryById;
static constexpr int kCancelledIdTtlSeconds = 600;
static std::thread g_cancelCleanupThread;
static std::condition_variable g_cancelCleanupCv;
static bool g_cancelCleanupStop = false;

// 一次性 init 保护：并发 init 会对 joinable 的 g_workerThread 重新赋值导致 std::terminate
static std::mutex g_initMutex;

static void cleanupCancelledTaskIdsLocked(std::chrono::steady_clock::time_point now) {
    while (!g_cancelledTaskExpirations.empty() &&
           g_cancelledTaskExpirations.begin()->first <= now) {
        auto expiry = g_cancelledTaskExpirations.begin();
        g_cancelledTaskIds.erase(expiry->second);
        g_cancelledTaskExpiryById.erase(expiry->second);
        g_cancelledTaskExpirations.erase(expiry);
    }
}

static void cancelledTaskCleanupLoop() {
    std::unique_lock<std::mutex> lock(g_cancelMutex);
    while (!g_cancelCleanupStop) {
        g_cancelCleanupCv.wait_for(lock, std::chrono::seconds(30),
                                   [] { return g_cancelCleanupStop; });
        if (g_cancelCleanupStop) break;
        cleanupCancelledTaskIdsLocked(std::chrono::steady_clock::now());
    }
}

static void startCancelledTaskCleanup() {
    std::lock_guard<std::mutex> lock(g_cancelMutex);
    g_cancelCleanupStop = false;
    g_cancelCleanupThread = std::thread(cancelledTaskCleanupLoop);
}

static void stopCancelledTaskCleanup() {
    {
        std::lock_guard<std::mutex> lock(g_cancelMutex);
        g_cancelCleanupStop = true;
    }
    g_cancelCleanupCv.notify_all();
    if (g_cancelCleanupThread.joinable()) g_cancelCleanupThread.join();
}

// probe / check_env / query_ffmpeg_features 跑在辅助线程上；追踪并统一 join，
// 避免库卸载（dlclose / DLL_PROCESS_DETACH）时这些线程仍在库代码内执行而崩溃。
static std::mutex g_auxThreadsMutex;
// [FIX H-11] 每个辅助线程绑定一个完成标志（shared_ptr<atomic<bool>>），
// 回收时只 join 已完成者，避免 swap 出仍在运行的线程并 join 阻塞在长任务
//（如 240s probe）上，造成后续请求被意外串行化。
struct AuxThread {
    std::thread thread;
    std::shared_ptr<std::atomic<bool>> done;
};
static std::vector<AuxThread> g_auxThreads;

static void spawnAuxThread(std::function<void()> fn) {
    // [FIX H-11] 只回收已完成线程：遍历 vector，done 为 true 的才 join 并移除，
    // 仍在运行的留待下一次 spawn 或 joinAuxThreads() 兜底回收，绝不阻塞在未完成任务上。
    {
        std::lock_guard<std::mutex> lock(g_auxThreadsMutex);
        for (auto it = g_auxThreads.begin(); it != g_auxThreads.end(); ) {
            if (it->done->load()) {
                if (it->thread.joinable()) it->thread.join();
                it = g_auxThreads.erase(it);
            } else {
                ++it;
            }
        }
    }

    std::lock_guard<std::mutex> lock(g_auxThreadsMutex);
    auto done = std::make_shared<std::atomic<bool>>(false);
    // Allocate vector storage before starting a joinable thread: allocation
    // failure during push_back would otherwise terminate the process.
    g_auxThreads.reserve(g_auxThreads.size() + 1);
    g_auxThreads.push_back(AuxThread{std::thread([fn = std::move(fn), done]() {
        try { fn(); } catch (...) { slog("aux thread: unhandled exception"); }
        done->store(true);
    }), done});
}

static void joinAuxThreads() {
    // 兜底回收：shutdown / DETACH 时等待所有辅助线程结束（此时允许阻塞）。
    std::vector<AuxThread> threads;
    {
        std::lock_guard<std::mutex> lock(g_auxThreadsMutex);
        threads.swap(g_auxThreads);
    }
    for (auto& t : threads) {
        if (t.thread.joinable()) t.thread.join();
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

        const std::string reqId = req.value("id", "");
        try {
            // 队列中已被取消的任务直接跳过（cancel 携带 task_ids 时），
            // 避免「停止所有」后后端仍继续执行排队任务
            {
                std::lock_guard<std::mutex> lock(g_cancelMutex);
                auto it = g_cancelledTaskIds.find(reqId);
                if (it != g_cancelledTaskIds.end()) {
                    g_cancelledTaskIds.erase(it);
                    auto expiry = g_cancelledTaskExpiryById.find(reqId);
                    if (expiry != g_cancelledTaskExpiryById.end()) {
                        g_cancelledTaskExpirations.erase(expiry->second);
                        g_cancelledTaskExpiryById.erase(expiry);
                    }
                    JsonWriter::reply(reqId, false, nullptr, "任务已取消");
                    continue;
                }
                cleanupCancelledTaskIdsLocked(std::chrono::steady_clock::now());
            }

            // 任务级取消标志：仅当本次请求的 id 已被取消才为 true。
            // 旧实现用全局 g_cancelFlag 并在任务启动时清零，导致「取消」被下一任务的
            // 启动清掉（取消失效）或误作用于其它任务（M-5）。这里改为按 id 判定。
            auto isCancelled = [reqId]() {
                if (g_cancelFlag.load()) return true;  // 全局「停止所有」仍生效
                std::lock_guard<std::mutex> lock(g_cancelMutex);
                return g_cancelledTaskIds.count(reqId) > 0;
            };

            // 把「当前任务 id」绑定到 worker 线程（暂停状态按 id 查询），
            // 请求结束时必须两件事都收回：
            //   1) 清空 thread-local id，避免下一次请求（或 probe 辅助线程）误用；
            //   2) 清掉该 id 的暂停标记 —— 否则同一个任务 id 重跑时会带着
            //      「已暂停」启动，ffmpeg 一 exec 就被 SIGSTOP，表现为启动即卡死。
            struct TaskIdScope {
                std::string id;
                explicit TaskIdScope(const std::string& taskId) : id(taskId) {
                    Subprocess::setCurrentTaskId(id);
                }
                ~TaskIdScope() {
                    Subprocess::setCurrentTaskId("");
                    Subprocess::setTaskPaused(id, false);
                }
                TaskIdScope(const TaskIdScope&) = delete;
                TaskIdScope& operator=(const TaskIdScope&) = delete;
            } taskScope(reqId);

            if (action == "transcode") {
                handleTranscode(req, isCancelled);
            } else if (action == "subtitle") {
                handleSubtitle(req, isCancelled);
            } else if (action == "extract_frame") {
                handleExtractFrame(req, isCancelled);
            } else if (action == "concat") {
                handleConcat(req, isCancelled);
            } else if (action == "image_sequence") {
                handleImageSequence(req, isCancelled);
            } else if (action == "custom_command") {
                handleCustomCommand(req, isCancelled);
            } else {
                JsonWriter::reply(reqId, false, nullptr, "未知 action: " + action);
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

    resetMessageQueues();
    {
        std::lock_guard<std::mutex> cancelLock(g_cancelMutex);
        g_cancelledTaskIds.clear();
        g_cancelledTaskExpirations.clear();
        g_cancelledTaskExpiryById.clear();
    }
    startCancelledTaskCleanup();
    // 重新初始化：上一个「会话」遗留的暂停标记不能带到本次运行。
    Subprocess::clearAllPaused();
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
    std::lock_guard<std::mutex> lifecycleLock(g_initMutex);
    if (!g_running.load() || g_shutdownFlag.load() || json_utf8 == nullptr) return -1;

    // [FIX S-5] 长度上限 4MB，防止超大输入导致 json::parse 申请巨量内存；
    // 手写扫描避免依赖 strnlen 的平台可用性差异（部分老 libc 可能缺失）。
    constexpr size_t kMaxRequestLen = 1u << 22;
    size_t len = 0;
    while (len < kMaxRequestLen && json_utf8[len] != '\0') ++len;
    if (len >= kMaxRequestLen) return -1;
    std::string line(json_utf8, len);
    slog("dll request: %s", line.substr(0, 200).c_str());

    // cancel/ping/shutdown 内联处理（不进工作线程队列）
    try {
        json req = json::parse(line);
        if (!req.is_object() || (req.contains("action") && !req["action"].is_string()) ||
            (req.contains("id") && !req["id"].is_string())) {
            JsonWriter::reply("unknown", false, nullptr, "请求 action/id 必须是字符串");
            return -1;
        }
        std::string action = req.value("action", "");

        if (action == "pause" || action == "resume") {
            // 暂停 / 恢复是**真实进程控制**（POSIX SIGSTOP/SIGCONT、
            // Windows NtSuspendProcess/NtResumeProcess），因此必须内联处理：
            // worker 线程此刻正阻塞在 runWithProgress 里等待这个信号，
            // 若把 pause 也塞进输入队列，它要等任务结束才会被处理 → 永远停不下来。
            auto params = req.value("params", json::object());
            const bool pause = action == "pause";
            std::vector<std::string> ids;
            if (params.contains("task_ids") && params["task_ids"].is_array()) {
                for (auto& tid : params["task_ids"]) {
                    if (tid.is_string()) {
                        const std::string id = tid.get<std::string>();
                        if (!id.empty()) ids.push_back(id);
                    }
                }
            }
            if (params.contains("task_id") && params["task_id"].is_string()) {
                const std::string id = params["task_id"].get<std::string>();
                if (!id.empty()) ids.push_back(id);
            }
            if (ids.empty()) {
                // 空 id 不做任何事，也绝不回 success —— 前端据此显示真实失败，
                // 而不是一个没有实际效果却显示「已暂停」的假状态。
                JsonWriter::reply(req.value("id", ""), false, nullptr,
                                  pause ? "pause 缺少 task_ids" : "resume 缺少 task_ids");
                return -1;
            }
            for (const auto& id : ids) Subprocess::setTaskPaused(id, pause);
            JsonWriter::reply(req.value("id", ""), true,
                              {{"message", pause ? "暂停信号已发送" : "恢复信号已发送"},
                               {"task_ids", ids}});
            return 0;
        }
        if (action == "cancel") {
            // 注意：不再无条件设置全局 g_cancelFlag。全局标志只在「停止所有」
            // （未携带 task_ids）时置位；精确取消由 g_cancelledTaskIds 按 id 判定。
            auto params = req.value("params", json::object());
            const bool hasTaskIds = params.contains("task_ids") && params["task_ids"].is_array()
                                    && !params["task_ids"].empty();
            if (!hasTaskIds) {
                g_cancelFlag.store(true);
            } else {
                std::lock_guard<std::mutex> lock(g_cancelMutex);
                auto now = std::chrono::steady_clock::now();
                for (auto& tid : params["task_ids"]) {
                    if (tid.is_string()) {
                        std::string id = tid.get<std::string>();
                        g_cancelledTaskIds.insert(id);
                        auto existing = g_cancelledTaskExpiryById.find(id);
                        if (existing != g_cancelledTaskExpiryById.end()) {
                            g_cancelledTaskExpirations.erase(existing->second);
                        }
                        auto expiry = g_cancelledTaskExpirations.emplace(
                            now + std::chrono::seconds(kCancelledIdTtlSeconds + 1), id);
                        g_cancelledTaskExpiryById[id] = expiry;
                    }
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
        if (action == "probe" || action == "check_env" || action == "query_ffmpeg_features" ||
            action == "fppx_import" ||
            action == "fppx2_import" || action == "fppx2_export" ||
            action == "fppx_legacy_import" || action == "fppx_legacy_export") {
            // 捕获 lambda 内的异常，避免线程内未捕获导致程序终止
            try {
                spawnAuxThread([req]() {
                    try {
                        const std::string act = req.value("action", "");
                        if (act == "probe") handleProbe(req);
                        else if (act == "check_env") handleCheckEnv(req);
                        else if (act == "query_ffmpeg_features") handleQueryFeatures(req);
                        else if (act == "fppx_import") handleFppxImport(req);
                        else if (act == "fppx2_import") handleFppx2Import(req);
                        else if (act == "fppx2_export") handleFppx2Export(req);
                        else if (act == "fppx_legacy_import") handleFppxLegacyImport(req);
                        else handleFppxLegacyExport(req);
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
    std::lock_guard<std::mutex> lifecycleLock(g_initMutex);
    if (!g_running.load()) return;

    slog("dll shutdown: starting");
    g_shutdownFlag.store(true);
    g_cancelFlag.store(true);
    // 挂起的子进程收不到「停止」信号；先清暂停标记，让 worker 的
    // runWithProgress 恢复并走正常终止路径，避免卸载时卡在 join 上。
    Subprocess::clearAllPaused();
    wakeInput();

    // 先等 probe/check_env/query_features 辅助线程退出，再停止输出与线程
    joinAuxThreads();

    if (g_workerThread.joinable()) {
        g_workerThread.join();
    }

    stopCancelledTaskCleanup();
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
        // [FIX S-4] lpReserved == nullptr 表示 FreeLibrary 显式卸载，进程仍存活，
        // 可安全做 C++ 收尾：置位退出标志并正确 join worker 与辅助线程，避免被
        // detach 的 worker 在静态对象（g_inputQueue/g_inputCv/JsonWriter 队列等）
        // 析构后继续访问已销毁的互斥量/条件变量/队列导致 UAF（退出时偶发崩溃/死锁）。
        // lpReserved != nullptr 表示进程正在终止，CRT 与 C++ 静态对象可能已被销毁，
        // 任何静态对象/分配器访问都是 UB，必须直接返回，不做任何收尾。
        if (lpReserved == nullptr && g_running.load()) {
            g_shutdownFlag.store(true);
            g_cancelFlag.store(true);
            wakeInput();                       // 唤醒阻塞在 popInput 的 worker
            if (g_workerThread.joinable()) g_workerThread.join();
            joinAuxThreads();                  // 回收仍在运行的辅助线程（与 shutdown 一致）
            stopCancelledTaskCleanup();
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
        stopCancelledTaskCleanup();
        g_running.store(false);
    }
}
#endif
