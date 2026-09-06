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
    DWORD n = 0;

    auto start = std::chrono::steady_clock::now();
    bool truncated = false;
    while (true) {
        DWORD avail = 0;
        PeekNamedPipe(hStdoutRead, nullptr, 0, nullptr, &avail, nullptr);
        if (avail > 0) {
            if (!ReadFile(hStdoutRead, buf, std::min((DWORD)sizeof(buf)-1, avail), &n, nullptr)) {
                // 管道读取失败（句柄异常/进程已终止且管道损坏）：终止读取，
                // 避免用未定义的 n 继续累积输出
                break;
            }
            if (stdout_data.size() + n > kMaxOutputBytes) {
                stdout_data.append(buf, std::min<size_t>(n, kMaxOutputBytes - stdout_data.size()));
            } else {
                stdout_data.append(buf, n);
            }
            if (stdout_data.size() >= kMaxOutputBytes) {
                truncated = true;
                TerminateProcess(pi.hProcess, 1);
                break;
            }
        }
        avail = 0;
        PeekNamedPipe(hStderrRead, nullptr, 0, nullptr, &avail, nullptr);
        if (avail > 0) {
            if (!ReadFile(hStderrRead, buf, std::min((DWORD)sizeof(buf)-1, avail), &n, nullptr)) {
                break;
            }
            if (stderr_data.size() + n > kMaxOutputBytes) {
                stderr_data.append(buf, std::min<size_t>(n, kMaxOutputBytes - stderr_data.size()));
            } else {
                stderr_data.append(buf, n);
            }
            if (stderr_data.size() >= kMaxOutputBytes) {
                truncated = true;
                TerminateProcess(pi.hProcess, 1);
                break;
            }
        }

        DWORD exit_code = 0;
        if (!GetExitCodeProcess(pi.hProcess, &exit_code)) {
            // 查询退出码失败（句柄异常等）：保守按失败退出，避免用
            // 未初始化的 exit_code 误判进程已退出/仍在运行
            result.exit_code = -1;
            break;
        }
        if (exit_code != STILL_ACTIVE) {
            result.exit_code = (int)exit_code;
            break;
        }

        if (timeout_sec > 0) {
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - start).count();
            if (elapsed >= timeout_sec) {
                TerminateProcess(pi.hProcess, 1);
                result.exit_code = -1;
                break;
            }
        }
        Sleep(10);
    }

    while (ReadFile(hStdoutRead, buf, sizeof(buf)-1, &n, nullptr) && n > 0) {
        stdout_data.append(buf, n);
    }
    while (ReadFile(hStderrRead, buf, sizeof(buf)-1, &n, nullptr) && n > 0) {
        stderr_data.append(buf, n);
    }

    result.stdout_output = stdout_data;
    result.stderr_output = stderr_data;
    result.output_truncated = truncated;

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

    // stderr 读取线程：缓冲读取（避免逐字节系统调用 + 每字节加锁），按 \r 和 \n 分割行
    std::mutex stderr_mutex;
    std::string stderr_line_buf;
    std::thread stderr_thread([hStderrRead, &on_stderr_line, &stderr_mutex, &stderr_line_buf]() {
        char buf[4096];
        DWORD n = 0;
        while (ReadFile(hStderrRead, buf, sizeof(buf), &n, nullptr) && n > 0) {
            size_t seg_start = 0;
            for (DWORD i = 0; i < n; ++i) {
                if (buf[i] == '\r' || buf[i] == '\n') {
                    // 行内片段一次加锁并入缓冲，避免逐字节加锁
                    if (i > seg_start) {
                        std::lock_guard<std::mutex> lock(stderr_mutex);
                        stderr_line_buf.append(buf + seg_start, i - seg_start);
                    }
                    seg_start = i + 1;
                    std::string line;
                    {
                        std::lock_guard<std::mutex> lock(stderr_mutex);
                        line.swap(stderr_line_buf);  // 移动而非拷贝
                    }
                    if (!line.empty() && line.back() == '\r') line.pop_back();
                    if (!line.empty()) {
                        try {
                            on_stderr_line(line);
                        } catch (...) {
                            // 回调异常不应导致线程崩溃
                        }
                    }
                }
            }
            if (n > seg_start) {
                std::lock_guard<std::mutex> lock(stderr_mutex);
                stderr_line_buf.append(buf + seg_start, n - seg_start);
            }
        }
    });

    // stdout 读取线程
    std::string stdout_data;
    std::thread stdout_thread([hStdoutRead, &stdout_data]() {
        char buf[4096];
        DWORD n = 0;
        while (ReadFile(hStdoutRead, buf, sizeof(buf), &n, nullptr) && n > 0) {
            stdout_data.append(buf, n);  // append(buf,n) 免去多余 strlen 扫描
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
                result.exit_code = -1;
                break;
            }
        }

        Sleep(100);
    }

    // 确保进程已退出后再关管道：若进程还没退出就 CloseHandle + join，
    // 阻塞在 ReadFile 上的读取线程不会因句柄关闭而返回，join 会永久死锁。
    if (WaitForSingleObject(pi.hProcess, 3000) != WAIT_OBJECT_0) {
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 3000);
    }
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

static void closeFd(int fd) {
    if (fd >= 0) close(fd);
}

// 创建一对「exec 后自动关闭」的管道。
//
// 关键修复（移动端「导入多个文件只有第一个能解析完成」）：此前用裸 pipe()
// 创建的读写两端都没有 FD_CLOEXEC，而本应用的 DLL 运行在 Flutter 应用进程内，
// 同一进程还会通过 dart:io 并发派生其它子进程（如列表卡片缩略图 ffmpeg）。
// 这些无关子进程会 fork 继承探测管道的写端，导致：
//   1) 探测子进程退出后父进程的排空 read() 因写端仍被外部持有而永远等不到
//      EOF —— 而 Subprocess::run 的 240s 超时只覆盖主等待循环，不覆盖这里，
//      于是后续所有 probe 请求全部挂死；
//   2) 表现为第一个文件正常出信息，其余一直卡在「解析中」。
// O_CLOEXEC 使这些 fd 在 exec 时自动关闭：自己的 stdout 经 dup2 复制到
// 1/2 不受影响（dup2 出的新 fd 无该标志），而无关兄弟进程再也无法继承。
static int createCloexecPipe(int fds[2]) {
#ifdef __linux__
    if (pipe2(fds, O_CLOEXEC) == 0) return 0;
#endif
    // pipe2 不可用（老内核/libc）时的等价回退
    if (pipe(fds) != 0) return -1;
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    return 0;
}

// 进程退出后的剩余输出排空：带总时长上限。
// 正常情况下（配合 O_CLOEXEC）读端立即 EOF，一次循环即返回；
// 上限只是防御性兜底，避免任何遗留写端把调用线程永久卡死。
static constexpr int kPostExitDrainMs = 15000;

static void drainFdBounded(int fd, std::string& out, bool& truncated,
                           std::chrono::steady_clock::time_point deadline) {
    char buf[4096];
    while (true) {
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n > 0) {
            if (out.size() + (size_t)n > kMaxOutputBytes) {
                out.append(buf, std::min<size_t>((size_t)n, kMaxOutputBytes - out.size()));
                truncated = true;
                continue;
            }
            out.append(buf, n);
            continue;
        }
        if (n == 0) return;                    // 真 EOF：全部读完
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            // 非阻塞 fd 暂无数据：短暂等待后重试，超过上限即放弃
            if (std::chrono::steady_clock::now() >= deadline) return;
            struct pollfd pfd = {fd, POLLIN | POLLHUP | POLLERR, 0};
            poll(&pfd, 1, 50);
            continue;
        }
        return;                                 // EINTR 以外/真实错误：放弃
    }
}

ProcessResult Subprocess::run(const std::vector<std::string>& cmd, int timeout_sec) {
    ProcessResult result;
    if (cmd.empty()) { result.exit_code = -1; return result; }

    int stdout_pipe[2], stderr_pipe[2];
    if (createCloexecPipe(stdout_pipe) != 0) {
        result.exit_code = -1;
        return result;
    }
    // 不能和上面写成 `||` 短路：那样第一个 pipe 成功、第二个失败时，
    // stdout_pipe 的两个 fd 就再也没人关了。
    if (createCloexecPipe(stderr_pipe) != 0) {
        closeFd(stdout_pipe[0]); closeFd(stdout_pipe[1]);
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
    bool truncated = false;

    while (!child_exited) {
        struct pollfd fds[2];
        fds[0] = {stdout_pipe[0], POLLIN, 0};
        fds[1] = {stderr_pipe[0], POLLIN, 0};
        poll(fds, 2, 10);

        if (fds[0].revents & POLLIN) {
            ssize_t n;
            while ((n = read(stdout_pipe[0], buf, sizeof(buf) - 1)) > 0) {
                if (stdout_data.size() + (size_t)n > kMaxOutputBytes) {
                    stdout_data.append(buf, std::min<size_t>((size_t)n, kMaxOutputBytes - stdout_data.size()));
                } else {
                    stdout_data.append(buf, n);
                }
                if (stdout_data.size() >= kMaxOutputBytes) {
                    truncated = true;
                    kill(pid, SIGKILL);
                    waitpid(pid, nullptr, 0);
                    child_exited = true;
                    break;
                }
            }
        }
        if (fds[1].revents & POLLIN) {
            ssize_t n;
            while ((n = read(stderr_pipe[0], buf, sizeof(buf) - 1)) > 0) {
                if (stderr_data.size() + (size_t)n > kMaxOutputBytes) {
                    stderr_data.append(buf, std::min<size_t>((size_t)n, kMaxOutputBytes - stderr_data.size()));
                } else {
                    stderr_data.append(buf, n);
                }
                if (stderr_data.size() >= kMaxOutputBytes) {
                    truncated = true;
                    kill(pid, SIGKILL);
                    waitpid(pid, nullptr, 0);
                    child_exited = true;
                    break;
                }
            }
        }
        if (child_exited) break;

        int status;
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w > 0) {
            if (WIFEXITED(status)) result.exit_code = WEXITSTATUS(status);
            // 子进程被信号终止：用负的信号编号传递，调用方可分辨
            //   exit_code == -11 -> SIGSEGV、-6 -> SIGABRT、-9 -> SIGKILL 等
            // 之前统一写成 -1，会把 SIGSEGV 等关键信息隐藏掉，前端就只能笼统报"执行失败-1"。
            else if (WIFSIGNALED(status)) result.exit_code = -WTERMSIG(status);
            child_exited = true;
            break;
        }

        if (timeout_sec > 0) {
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - start).count();
            if (elapsed >= timeout_sec) {
                kill(pid, SIGKILL);
                waitpid(pid, nullptr, 0);
                result.exit_code = -1;
                child_exited = true;
                break;
            }
        }
    }

    // 读取剩余数据（带上限：见 drainFdBounded 注释，防止遗留写端导致永久阻塞）
    const auto drainDeadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(kPostExitDrainMs);
    drainFdBounded(stdout_pipe[0], stdout_data, truncated, drainDeadline);
    drainFdBounded(stderr_pipe[0], stderr_data, truncated, drainDeadline);

    result.stdout_output = stdout_data;
    result.stderr_output = stderr_data;
    result.output_truncated = truncated;

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
    // O_CLOEXEC：修复与 Subprocess::run 相同的 fd 泄漏问题 ——
    // ffmpeg 长转码期间并发的无关子进程（缩略图/探测）若继承这些管道写端，
    // 读取线程同样会在进程退出后永远等不到 EOF。
    if (createCloexecPipe(stdout_pipe) != 0) {
        result.exit_code = -1;
        return result;
    }
    // 不能和上面写成 `||` 短路：那样第一个 pipe 成功、第二个失败时，
    // stdout_pipe 的两个 fd 就再也没人关了。
    if (createCloexecPipe(stderr_pipe) != 0) {
        closeFd(stdout_pipe[0]); closeFd(stdout_pipe[1]);
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

    // stderr 读取线程：缓冲读取（避免逐字节系统调用 + 每字节加锁），按 \r 和 \n 分割行
    std::mutex stderr_mutex;
    std::string stderr_line_buf;
    int stderr_fd = stderr_pipe[0];
    std::thread stderr_thread([stderr_fd, &on_stderr_line, &stderr_mutex, &stderr_line_buf]() {
        char buf[4096];
        ssize_t n;
        while ((n = read(stderr_fd, buf, sizeof(buf))) > 0) {
            size_t seg_start = 0;
            for (ssize_t i = 0; i < n; ++i) {
                if (buf[i] == '\r' || buf[i] == '\n') {
                    if (i > (ssize_t)seg_start) {
                        std::lock_guard<std::mutex> lock(stderr_mutex);
                        stderr_line_buf.append(buf + seg_start, (size_t)i - seg_start);
                    }
                    seg_start = (size_t)i + 1;
                    std::string line;
                    {
                        std::lock_guard<std::mutex> lock(stderr_mutex);
                        line.swap(stderr_line_buf);  // 移动而非拷贝
                    }
                    if (!line.empty() && line.back() == '\r') line.pop_back();
                    if (!line.empty()) {
                        try { on_stderr_line(line); } catch (...) {}
                    }
                }
            }
            if ((size_t)n > seg_start) {
                std::lock_guard<std::mutex> lock(stderr_mutex);
                stderr_line_buf.append(buf + seg_start, (size_t)n - seg_start);
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
            stdout_data.append(buf, n);
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
            // 与 Subprocess::run 保持一致：用负信号编号传递信号终止语义。
            else if (WIFSIGNALED(status)) result.exit_code = -WTERMSIG(status);
            break;
        }

        if (timeout_sec > 0) {
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - start).count();
            if (elapsed >= timeout_sec) {
                kill(pid, SIGKILL);
                waitpid(pid, nullptr, 0);
                result.exit_code = -1;
                break;
            }
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    // 子进程已被 waitpid 回收（上面所有 break 路径均已 kill+waitpid 或 waitpid 成功），
    // 写端随子进程退出而关闭，读取线程的 read() 会返回 0 自然退出。
    // 因此先 join，等线程退出后再关闭读端 fd，避免「线程仍阻塞在读端、
    // 另一线程关闭同一 fd」导致的 fd 复用竞态。
    if (stderr_thread.joinable()) stderr_thread.join();
    if (stdout_thread.joinable()) stdout_thread.join();
    
    // 线程已退出，安全关闭读端
    closeFd(stderr_pipe[0]);
    closeFd(stdout_pipe[0]);

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
