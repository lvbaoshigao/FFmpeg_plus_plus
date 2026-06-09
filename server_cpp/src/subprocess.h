#pragma once
#include <string>
#include <vector>
#include <functional>
#include <atomic>
#include <thread>
#include <windows.h>
#include <algorithm>

namespace ffmpegpp {

struct ProcessResult {
    int exit_code = -1;
    std::string stdout_output;
    std::string stderr_output;
    bool timed_out = false;
};

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

private:
    static std::string vectorToCommandLine(const std::vector<std::string>& cmd);
};

} // namespace ffmpegpp
