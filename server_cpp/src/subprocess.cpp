#include "subprocess.h"
#include <sstream>
#include <chrono>
#include <cstring>
#include <algorithm>
#include <thread>
#include <mutex>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <signal.h>
#include <fcntl.h>
#include <poll.h>
#include <cerrno>
#endif

namespace ffmpegpp {

#ifdef _WIN32

// ═══════════════════════════════════════════════
// Windows 实现
// ═══════════════════════════════════════════════

// UTF-8 → UTF-16 宽字符串转换
std::wstring Subprocess::utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    if (len <= 0) return L"";
    std::wstring ws(len, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &ws[0], len);
    return ws;
}

// UTF-16 → UTF-8 转换
std::string Subprocess::wideToUtf8(const std::wstring& ws) {
    if (ws.empty()) return "";
    int len = WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), (int)ws.size(), nullptr, 0, nullptr, nullptr);
    if (len <= 0) return "";
    std::string s(len, '\0');
    WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), (int)ws.size(), &s[0], len, nullptr, nullptr);
    return s;
}

// 判断参数是否需要加引号（含空格、逗号、中文等特殊字符）
static bool needsQuoting(const std::string& s) {
    for (char c : s) {
        if (c == ' ' || c == '\t' || c == '"' || c == ',' || c == ';' || c == '='
            || c == '[' || c == ']' || c == '(' || c == ')' || c == '&' || c == '^' || c == '%')
            return true;
        // 非 ASCII 字符（中文等）也需要加引号
        if ((unsigned char)c > 127) return true;
    }
    return false;
}

// Windows 命令行参数转义（遵循 MSVC CRT 的 argv 解析规则）
// 规则：反斜杠仅在紧接双引号时才需要转义（连续 N 个 \ 后跟 " → 2N 个 \ + \"）
static std::string escapeArgument(const std::string& arg) {
    if (arg.empty()) return "\"\"";
    if (!needsQuoting(arg)) return arg;

    std::string result = "\"";
    for (size_t i = 0; i < arg.size(); ++i) {
        if (arg[i] == '\\') {
            size_t numBackslashes = 0;
            while (i < arg.size() && arg[i] == '\\') {
                ++numBackslashes;
                ++i;
            }
            if (i == arg.size()) {
                // 参数末尾的反斜杠：在闭合引号前必须加倍
                result.append(numBackslashes * 2, '\\');
            } else if (arg[i] == '"') {
                // 反斜杠后跟引号：反斜杠加倍 + 转义引号
                result.append(numBackslashes * 2, '\\');
                result += "\\\"";
            } else {
                // 反斜杠后跟普通字符：保持原样
                result.append(numBackslashes, '\\');
                result += arg[i];
            }
        } else if (arg[i] == '"') {
            result += "\\\"";
        } else {
            result += arg[i];
        }
    }
    result += '"';
    return result;
}

std::string Subprocess::vectorToCommandLine(const std::vector<std::string>& cmd) {
    std::ostringstream oss;
    for (size_t i = 0; i < cmd.size(); ++i) {
        if (i > 0) oss << " ";
        oss << escapeArgument(cmd[i]);
    }
    return oss.str();
}

ProcessResult Subprocess::run(const std::vector<std::string>& cmd, int timeout_sec) {
    ProcessResult result;
    if (cmd.empty()) { result.exit_code = -1; return result; }

    std::string cmdline = vectorToCommandLine(cmd);
    std::wstring wcmdline = utf8ToWide(cmdline);

    SECURITY_ATTRIBUTES sa = {sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    HANDLE hStdoutRead, hStdoutWrite, hStderrRead, hStderrWrite;
    if (!CreatePipe(&hStdoutRead, &hStdoutWrite, &sa, 0) ||
        !CreatePipe(&hStderrRead, &hStderrWrite, &sa, 0)) {
        result.exit_code = -1;
        return result;
    }
    SetHandleInformation(hStdoutRead, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(hStderrRead, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    si.hStdOutput = hStdoutWrite;
    si.hStdError = hStderrWrite;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.dwFlags = STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi = {};
    // CreateProcessW 要求可修改的命令行缓冲区
    std::vector<wchar_t> cmdBuf(wcmdline.begin(), wcmdline.end());
    cmdBuf.push_back(L'\0');
    BOOL ok = CreateProcessW(nullptr, cmdBuf.data(),
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
    std::wstring wcmdline = utf8ToWide(cmdline);

    SECURITY_ATTRIBUTES sa = {sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    HANDLE hStdoutRead, hStdoutWrite, hStderrRead, hStderrWrite;
    if (!CreatePipe(&hStdoutRead, &hStdoutWrite, &sa, 0) ||
        !CreatePipe(&hStderrRead, &hStderrWrite, &sa, 0)) {
        result.exit_code = -1;
        return result;
    }
    SetHandleInformation(hStdoutRead, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(hStderrRead, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    si.hStdOutput = hStdoutWrite;
    si.hStdError = hStderrWrite;
    // stdin 设为 NUL，不继承父进程的 stdin（它会干扰管道读取，导致 stderr 数据被缓冲）
    HANDLE hNul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ, &sa, OPEN_EXISTING, 0, nullptr);
    si.hStdInput = (hNul != INVALID_HANDLE_VALUE) ? hNul : GetStdHandle(STD_INPUT_HANDLE);
    si.dwFlags = STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi = {};
    std::vector<wchar_t> cmdBuf(wcmdline.begin(), wcmdline.end());
    cmdBuf.push_back(L'\0');
    BOOL ok = CreateProcessW(nullptr, cmdBuf.data(),
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
                    try {
                        on_stderr_line(line);
                    } catch (...) {
                        // 回调异常不应导致线程崩溃
                    }
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

#else

// ═══════════════════════════════════════════════
// Linux / POSIX 实现
// ═══════════════════════════════════════════════

std::string Subprocess::vectorToCommandLine(const std::vector<std::string>& cmd) {
    std::ostringstream oss;
    for (size_t i = 0; i < cmd.size(); ++i) {
        if (i > 0) oss << " ";
        oss << cmd[i];
    }
    return oss.str();
}

static void closeFd(int fd) {
    if (fd >= 0) close(fd);
}

ProcessResult Subprocess::run(const std::vector<std::string>& cmd, int timeout_sec) {
    ProcessResult result;
    if (cmd.empty()) { result.exit_code = -1; return result; }

    int stdout_pipe[2], stderr_pipe[2];
    if (pipe(stdout_pipe) != 0 || pipe(stderr_pipe) != 0) {
        result.exit_code = -1;
        return result;
    }

    pid_t pid = fork();
    if (pid < 0) {
        closeFd(stdout_pipe[0]); closeFd(stdout_pipe[1]);
        closeFd(stderr_pipe[0]); closeFd(stderr_pipe[1]);
        result.exit_code = -1;
        return result;
    }

    if (pid == 0) {
        // 子进程
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            close(devnull);
        }

        std::vector<char*> argv;
        for (const auto& s : cmd) argv.push_back(const_cast<char*>(s.c_str()));
        argv.push_back(nullptr);
        execvp(argv[0], argv.data());
        _exit(127);
    }

    // 父进程
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);

    // 设置非阻塞
    fcntl(stdout_pipe[0], F_SETFL, fcntl(stdout_pipe[0], F_GETFL) | O_NONBLOCK);
    fcntl(stderr_pipe[0], F_SETFL, fcntl(stderr_pipe[0], F_GETFL) | O_NONBLOCK);

    std::string stdout_data, stderr_data;
    char buf[4096];

    auto start = std::chrono::steady_clock::now();
    bool child_exited = false;

    while (!child_exited) {
        struct pollfd fds[2];
        fds[0] = {stdout_pipe[0], POLLIN, 0};
        fds[1] = {stderr_pipe[0], POLLIN, 0};
        poll(fds, 2, 10);

        if (fds[0].revents & POLLIN) {
            ssize_t n;
            while ((n = read(stdout_pipe[0], buf, sizeof(buf) - 1)) > 0) {
                buf[n] = 0; stdout_data += buf;
            }
        }
        if (fds[1].revents & POLLIN) {
            ssize_t n;
            while ((n = read(stderr_pipe[0], buf, sizeof(buf) - 1)) > 0) {
                buf[n] = 0; stderr_data += buf;
            }
        }

        int status;
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w > 0) {
            if (WIFEXITED(status)) result.exit_code = WEXITSTATUS(status);
            else if (WIFSIGNALED(status)) result.exit_code = -1;
            child_exited = true;
            break;
        }

        if (timeout_sec > 0) {
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - start).count();
            if (elapsed >= timeout_sec) {
                kill(pid, SIGKILL);
                waitpid(pid, nullptr, 0);
                result.timed_out = true;
                result.exit_code = -1;
                child_exited = true;
                break;
            }
        }
    }

    // 读取剩余数据
    ssize_t n;
    while ((n = read(stdout_pipe[0], buf, sizeof(buf) - 1)) > 0) {
        buf[n] = 0; stdout_data += buf;
    }
    while ((n = read(stderr_pipe[0], buf, sizeof(buf) - 1)) > 0) {
        buf[n] = 0; stderr_data += buf;
    }

    result.stdout_output = stdout_data;
    result.stderr_output = stderr_data;

    closeFd(stdout_pipe[0]);
    closeFd(stderr_pipe[0]);

    return result;
}

ProcessResult Subprocess::runWithProgress(
    const std::vector<std::string>& cmd,
    std::function<void(const std::string&)> on_stderr_line,
    std::atomic<bool>& cancel_flag,
    int timeout_sec) {

    ProcessResult result;
    if (cmd.empty()) { result.exit_code = -1; return result; }

    int stdout_pipe[2], stderr_pipe[2];
    if (pipe(stdout_pipe) != 0 || pipe(stderr_pipe) != 0) {
        result.exit_code = -1;
        return result;
    }

    pid_t pid = fork();
    if (pid < 0) {
        closeFd(stdout_pipe[0]); closeFd(stdout_pipe[1]);
        closeFd(stderr_pipe[0]); closeFd(stderr_pipe[1]);
        result.exit_code = -1;
        return result;
    }

    if (pid == 0) {
        // 子进程
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            close(devnull);
        }

        std::vector<char*> argv;
        for (const auto& s : cmd) argv.push_back(const_cast<char*>(s.c_str()));
        argv.push_back(nullptr);
        execvp(argv[0], argv.data());
        _exit(127);
    }

    // 父进程
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);

    // stderr 读取线程
    std::mutex stderr_mutex;
    std::string stderr_line_buf;
    int stderr_fd = stderr_pipe[0];
    std::thread stderr_thread([stderr_fd, &on_stderr_line, &stderr_mutex, &stderr_line_buf]() {
        char ch;
        ssize_t n;
        while ((n = read(stderr_fd, &ch, 1)) > 0) {
            if (ch == '\r' || ch == '\n') {
                std::string line;
                {
                    std::lock_guard<std::mutex> lock(stderr_mutex);
                    line = stderr_line_buf;
                    stderr_line_buf.clear();
                }
                if (!line.empty() && line.back() == '\r') line.pop_back();
                if (!line.empty()) {
                    try { on_stderr_line(line); } catch (...) {}
                }
            } else {
                std::lock_guard<std::mutex> lock(stderr_mutex);
                stderr_line_buf += ch;
            }
        }
    });

    // stdout 读取线程
    std::string stdout_data;
    int stdout_fd = stdout_pipe[0];
    std::thread stdout_thread([stdout_fd, &stdout_data]() {
        char buf[4096];
        ssize_t n;
        while ((n = read(stdout_fd, buf, sizeof(buf) - 1)) > 0) {
            buf[n] = 0;
            stdout_data += buf;
        }
    });

    // 主线程：等待进程退出或取消
    auto start = std::chrono::steady_clock::now();
    while (true) {
        if (cancel_flag.load()) {
            kill(pid, SIGKILL);
            waitpid(pid, nullptr, 0);
            result.exit_code = -1;
            break;
        }

        int status;
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w > 0) {
            if (WIFEXITED(status)) result.exit_code = WEXITSTATUS(status);
            else if (WIFSIGNALED(status)) result.exit_code = -1;
            break;
        }

        if (timeout_sec > 0) {
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - start).count();
            if (elapsed >= timeout_sec) {
                kill(pid, SIGKILL);
                waitpid(pid, nullptr, 0);
                result.timed_out = true;
                result.exit_code = -1;
                break;
            }
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    // 关闭管道，让读取线程结束
    closeFd(stderr_pipe[0]);
    closeFd(stdout_pipe[0]);
    if (stderr_thread.joinable()) stderr_thread.join();
    if (stdout_thread.joinable()) stdout_thread.join();

    result.stdout_output = stdout_data;
    {
        std::lock_guard<std::mutex> lock(stderr_mutex);
        if (!stderr_line_buf.empty()) {
            on_stderr_line(stderr_line_buf);
        }
    }

    return result;
}

#endif // _WIN32

} // namespace ffmpegpp
