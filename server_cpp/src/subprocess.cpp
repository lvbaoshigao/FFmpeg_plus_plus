#include "subprocess.h"
#include <sstream>
#include <chrono>
#include <cstring>
#include <algorithm>
#include <thread>
#include <mutex>
#include <windows.h>

namespace ffmpegpp {

std::string Subprocess::vectorToCommandLine(const std::vector<std::string>& cmd) {
    std::ostringstream oss;
    for (size_t i = 0; i < cmd.size(); ++i) {
        if (i > 0) oss << " ";
        if (cmd[i].find(' ') != std::string::npos) {
            oss << "\"" << cmd[i] << "\"";
        } else {
            oss << cmd[i];
        }
    }
    return oss.str();
}

ProcessResult Subprocess::run(const std::vector<std::string>& cmd, int timeout_sec) {
    ProcessResult result;
    if (cmd.empty()) { result.exit_code = -1; return result; }

    std::string cmdline = vectorToCommandLine(cmd);

    SECURITY_ATTRIBUTES sa = {sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    HANDLE hStdoutRead, hStdoutWrite, hStderrRead, hStderrWrite;
    CreatePipe(&hStdoutRead, &hStdoutWrite, &sa, 0);
    CreatePipe(&hStderrRead, &hStderrWrite, &sa, 0);
    SetHandleInformation(hStdoutRead, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(hStderrRead, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si = {};
    si.cb = sizeof(si);
    si.hStdOutput = hStdoutWrite;
    si.hStdError = hStderrWrite;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.dwFlags = STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi = {};
    BOOL ok = CreateProcessA(nullptr, (LPSTR)cmdline.c_str(),
                             nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
                             nullptr, nullptr, &si, &pi);
    CloseHandle(hStdoutWrite);
    CloseHandle(hStderrWrite);

    if (!ok) {
        CloseHandle(hStdoutRead);
        CloseHandle(hStderrRead);
        result.exit_code = -1;
        return result;
    }

    std::string stdout_data, stderr_data;
    char buf[4096];
    DWORD n;

    auto start = std::chrono::steady_clock::now();
    while (true) {
        DWORD avail = 0;
        PeekNamedPipe(hStdoutRead, nullptr, 0, nullptr, &avail, nullptr);
        if (avail > 0) {
            ReadFile(hStdoutRead, buf, std::min((DWORD)sizeof(buf)-1, avail), &n, nullptr);
            buf[n] = 0; stdout_data += buf;
        }
        avail = 0;
        PeekNamedPipe(hStderrRead, nullptr, 0, nullptr, &avail, nullptr);
        if (avail > 0) {
            ReadFile(hStderrRead, buf, std::min((DWORD)sizeof(buf)-1, avail), &n, nullptr);
            buf[n] = 0; stderr_data += buf;
        }

        DWORD exit_code;
        GetExitCodeProcess(pi.hProcess, &exit_code);
        if (exit_code != STILL_ACTIVE) {
            result.exit_code = (int)exit_code;
            break;
        }

        if (timeout_sec > 0) {
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - start).count();
            if (elapsed >= timeout_sec) {
                TerminateProcess(pi.hProcess, 1);
                result.timed_out = true;
                result.exit_code = -1;
                break;
            }
        }
        Sleep(10);
    }

    while (ReadFile(hStdoutRead, buf, sizeof(buf)-1, &n, nullptr) && n > 0) {
        buf[n] = 0; stdout_data += buf;
    }
    while (ReadFile(hStderrRead, buf, sizeof(buf)-1, &n, nullptr) && n > 0) {
        buf[n] = 0; stderr_data += buf;
    }

    result.stdout_output = stdout_data;
    result.stderr_output = stderr_data;

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hStdoutRead);
    CloseHandle(hStderrRead);

    return result;
}

ProcessResult Subprocess::runWithProgress(
    const std::vector<std::string>& cmd,
    std::function<void(const std::string&)> on_stderr_line,
    std::atomic<bool>& cancel_flag,
    int timeout_sec) {

    ProcessResult result;
    if (cmd.empty()) { result.exit_code = -1; return result; }

    std::string cmdline = vectorToCommandLine(cmd);

    SECURITY_ATTRIBUTES sa = {sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    HANDLE hStdoutRead, hStdoutWrite, hStderrRead, hStderrWrite;
    CreatePipe(&hStdoutRead, &hStdoutWrite, &sa, 0);
    CreatePipe(&hStderrRead, &hStderrWrite, &sa, 0);
    SetHandleInformation(hStdoutRead, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(hStderrRead, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si = {};
    si.cb = sizeof(si);
    si.hStdOutput = hStdoutWrite;
    si.hStdError = hStderrWrite;
    // stdin 设为 NUL，不继承父进程的 stdin（它会干扰管道读取，导致 stderr 数据被缓冲）
    HANDLE hNul = CreateFileA("NUL", GENERIC_READ, FILE_SHARE_READ, &sa, OPEN_EXISTING, 0, nullptr);
    si.hStdInput = (hNul != INVALID_HANDLE_VALUE) ? hNul : GetStdHandle(STD_INPUT_HANDLE);
    si.dwFlags = STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi = {};
    BOOL ok = CreateProcessA(nullptr, (LPSTR)cmdline.c_str(),
                             nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
                             nullptr, nullptr, &si, &pi);
    CloseHandle(hStdoutWrite);
    CloseHandle(hStderrWrite);
    if (hNul != INVALID_HANDLE_VALUE) CloseHandle(hNul);

    if (!ok) {
        CloseHandle(hStdoutRead);
        CloseHandle(hStderrRead);
        result.exit_code = -1;
        return result;
    }

    // stderr 读取线程：逐字节读取（避免 C 运行时缓冲），按 \r 和 \n 分割行
    std::mutex stderr_mutex;
    std::string stderr_line_buf;
    std::thread stderr_thread([hStderrRead, &on_stderr_line, &stderr_mutex, &stderr_line_buf]() {
        char ch;
        DWORD n;
        while (ReadFile(hStderrRead, &ch, 1, &n, nullptr) && n > 0) {
            if (ch == '\r' || ch == '\n') {
                std::string line;
                {
                    std::lock_guard<std::mutex> lock(stderr_mutex);
                    line = stderr_line_buf;
                    stderr_line_buf.clear();
                }
                if (!line.empty() && line.back() == '\r') line.pop_back();
                if (!line.empty()) {
                    on_stderr_line(line);
                }
            } else {
                std::lock_guard<std::mutex> lock(stderr_mutex);
                stderr_line_buf += ch;
            }
        }
    });

    // stdout 读取线程
    std::string stdout_data;
    std::thread stdout_thread([hStdoutRead, &stdout_data]() {
        char buf[4096];
        DWORD n;
        while (ReadFile(hStdoutRead, buf, sizeof(buf) - 1, &n, nullptr) && n > 0) {
            buf[n] = 0;
            stdout_data += buf;
        }
    });

    // 主线程：等待进程退出或取消
    auto start = std::chrono::steady_clock::now();
    while (true) {
        if (cancel_flag.load()) {
            TerminateProcess(pi.hProcess, 1);
            result.exit_code = -1;
            break;
        }

        DWORD exit_code;
        if (GetExitCodeProcess(pi.hProcess, &exit_code) && exit_code != STILL_ACTIVE) {
            result.exit_code = (int)exit_code;
            break;
        }

        if (timeout_sec > 0) {
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - start).count();
            if (elapsed >= timeout_sec) {
                TerminateProcess(pi.hProcess, 1);
                result.timed_out = true;
                result.exit_code = -1;
                break;
            }
        }

        Sleep(100);
    }

    // 等待读取线程结束
    WaitForSingleObject(pi.hProcess, 3000);
    CloseHandle(hStderrRead);
    CloseHandle(hStdoutRead);
    if (stderr_thread.joinable()) stderr_thread.join();
    if (stdout_thread.joinable()) stdout_thread.join();

    result.stdout_output = stdout_data;
    {
        std::lock_guard<std::mutex> lock(stderr_mutex);
        if (!stderr_line_buf.empty()) {
            on_stderr_line(stderr_line_buf);
        }
    }

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return result;
}

} // namespace ffmpegpp
