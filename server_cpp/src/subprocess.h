#pragma once
#include <string>
#include <vector>
#include <functional>
#include <atomic>
#include <thread>
#include <algorithm>
#ifdef _WIN32
#include <windows.h>
#endif

namespace ffmpegpp {

struct ProcessResult {
    int exit_code = -1;
    std::string stdout_output;
    std::string stderr_output;
    bool timed_out = false;
    bool output_truncated = false;  // 累积输出超过 max_output_bytes 时置 true
};

// 子进程 stdout/stderr 累积上限。超过此值认为子进程失控（典型情况：
// ffprobe 对 1GB+ 视频走 -show_streams 输出 10MB+ JSON），立刻 kill 并
// 让 probe.cpp 把 result.output_truncated 翻译成友好错误。
// 16MB 足够任何合理场景（正常 probe 仅 2-5KB），同时防止
// Android 1GB 进程堆被吃光触发 OOM。
constexpr size_t kMaxOutputBytes = 16 * 1024 * 1024;

class Subprocess {
public:
    // 同步执行命令，返回结果
    static ProcessResult run(const std::vector<std::string>& cmd,
                             int timeout_sec = 0);

    // 异步执行，通过回调实时输出 stderr 每一行
    // cancel_flag 为 true 时立即终止进程
    static ProcessResult runWithProgress(
        const std::vector<std::string>& cmd,
        std::function<void(const std::string& line)> on_stderr_line,
        std::atomic<bool>& cancel_flag,
        int timeout_sec = 0);

#ifdef _WIN32
    static std::wstring utf8ToWide(const std::string& s);
    static std::string wideToUtf8(const std::wstring& ws);
#endif

private:
    static std::string vectorToCommandLine(const std::vector<std::string>& cmd);
};

} // namespace ffmpegpp
