#include "installer.h"
#include "subprocess.h"
#include <mutex>
#ifdef _WIN32
#include <windows.h>
#else
#include <climits>
#include <unistd.h>
#include <cstdlib>
#include <cstring>
#endif
#include <filesystem>
#include <sstream>

namespace ffmpegpp {

namespace fs = std::filesystem;

namespace {
std::string findExecutable(const std::string& name) {
#ifdef _WIN32
    // 1. 检查 PATH
    wchar_t wbuf[MAX_PATH];
    std::wstring wname = Subprocess::utf8ToWide(name);
    DWORD len = SearchPathW(nullptr, wname.c_str(), L".exe", MAX_PATH, wbuf, nullptr);
    if (len > 0 && len < MAX_PATH) return Subprocess::wideToUtf8(std::wstring(wbuf, len));

    // 2. 常见安装目录
    std::vector<std::string> candidates = {
        "C:/ffmpeg/bin/" + name + ".exe",
        "C:/Program Files/ffmpeg/bin/" + name + ".exe",
    };
    // 用户目录
    char* userProfile = getenv("USERPROFILE");
    if (userProfile) {
        candidates.push_back(std::string(userProfile) + "/ffmpeg/bin/" + name + ".exe");
        candidates.push_back(std::string(userProfile) + "/AppData/Local/ffmpeg/bin/" + name + ".exe");
    }
    for (auto& c : candidates) {
        if (fs::exists(c)) return c;
    }
    return "";
#else
    // 1. 在 PATH 中搜索
    const char* pathEnv = getenv("PATH");
    if (pathEnv) {
        std::string pathStr(pathEnv);
        std::istringstream iss(pathStr);
        std::string dir;
        while (std::getline(iss, dir, ':')) {
            std::string candidate = dir + "/" + name;
            if (access(candidate.c_str(), X_OK) == 0) return candidate;
        }
    }

    // 2. 常见安装目录
    std::vector<std::string> candidates = {
        "/usr/bin/" + name,
        "/usr/local/bin/" + name,
        "/snap/bin/" + name,
    };
    const char* home = getenv("HOME");
    if (home) {
        candidates.push_back(std::string(home) + "/.local/bin/" + name);
    }
    for (auto& c : candidates) {
        if (access(c.c_str(), X_OK) == 0) return c;
    }
    return "";
#endif
}

ToolCheck checkTool(const std::string& name) {
    ToolCheck result;
    result.path = findExecutable(name);
    if (result.path.empty()) {
        result.error = name + " 未在 PATH 或常见安装目录中找到";
        return result;
    }
    auto pr = Subprocess::run({result.path, "-version"}, 10);
    if (pr.exit_code == 0 && !pr.stdout_output.empty()) {
        auto nl = pr.stdout_output.find('\n');
        result.version = (nl != std::string::npos) ? pr.stdout_output.substr(0, nl) : pr.stdout_output;
        // 去掉 \r
        if (!result.version.empty() && result.version.back() == '\r') result.version.pop_back();
        result.found = true;
    } else {
        result.error = "在 " + result.path + " 找到 " + name + "，但执行 -version 失败";
    }
    return result;
}
} // namespace

ToolCheck findFFmpeg() { return checkTool("ffmpeg"); }
ToolCheck findFFprobe() { return checkTool("ffprobe"); }

// 缓存已解析的完整路径，避免每次构建命令都重新搜索
static std::string g_ffmpegPath;
static std::string g_ffprobePath;
static std::once_flag g_ffmpegOnce;
static std::once_flag g_ffprobeOnce;

const std::string& getFFmpegPath() {
    std::call_once(g_ffmpegOnce, []() {
        g_ffmpegPath = findExecutable("ffmpeg");
        if (g_ffmpegPath.empty()) g_ffmpegPath = "ffmpeg";
    });
    return g_ffmpegPath;
}

const std::string& getFFprobePath() {
    std::call_once(g_ffprobeOnce, []() {
        g_ffprobePath = findExecutable("ffprobe");
        if (g_ffprobePath.empty()) g_ffprobePath = "ffprobe";
    });
    return g_ffprobePath;
}

json ensureFFmpeg() {
    auto ff_path = getFFmpegPath();
    auto fp_path = getFFprobePath();
    bool ff_found = !ff_path.empty() && ff_path != "ffmpeg";
    bool fp_found = !fp_path.empty() && fp_path != "ffprobe";

    std::string ff_version, fp_version, ff_error, fp_error;
    if (ff_found) {
        auto pr = Subprocess::run({ff_path, "-version"}, 10);
        if (pr.exit_code == 0 && !pr.stdout_output.empty()) {
            auto nl = pr.stdout_output.find('\n');
            ff_version = (nl != std::string::npos) ? pr.stdout_output.substr(0, nl) : pr.stdout_output;
            if (!ff_version.empty() && ff_version.back() == '\r') ff_version.pop_back();
        } else {
            ff_error = "执行 -version 失败";
        }
    } else {
        ff_error = "ffmpeg 未在 PATH 或常见安装目录中找到";
    }
    if (fp_found) {
        auto pr = Subprocess::run({fp_path, "-version"}, 10);
        if (pr.exit_code == 0 && !pr.stdout_output.empty()) {
            auto nl = pr.stdout_output.find('\n');
            fp_version = (nl != std::string::npos) ? pr.stdout_output.substr(0, nl) : pr.stdout_output;
            if (!fp_version.empty() && fp_version.back() == '\r') fp_version.pop_back();
        } else {
            fp_error = "执行 -version 失败";
        }
    } else {
        fp_error = "ffprobe 未在 PATH 或常见安装目录中找到";
    }

    return {
        {"ffmpeg", {{"found", ff_found}, {"path", ff_path}, {"version", ff_version}, {"error", ff_error}}},
        {"ffprobe", {{"found", fp_found}, {"path", fp_path}, {"version", fp_version}, {"error", fp_error}}},
        {"all_ok", ff_found && fp_found},
    };
}

json getInstallGuide() {
#ifdef _WIN32
    return {
        {"platform", "windows"},
        {"download_url", "https://ffmpeg.org/download.html#build-windows"},
        {"steps", {
            "1. 打开 https://ffmpeg.org/download.html",
            "2. 在 'Windows Builds' 区域，选择 gyan.dev 或 BtbN 的预编译版本",
            "3. 推荐下载: 'ffmpeg-release-full.7z'",
            "4. 解压到固定目录，如 C:\\ffmpeg",
            "5. 将 C:\\ffmpeg\\bin 添加到系统 PATH 环境变量",
            "6. 打开新的 cmd 窗口，输入 ffmpeg -version 验证",
        }},
    };
#else
    return {
        {"platform", "linux"},
        {"download_url", "https://ffmpeg.org/download.html#build-linux"},
        {"steps", {
            "1. Debian/Ubuntu: sudo apt install ffmpeg",
            "2. Fedora: sudo dnf install ffmpeg",
            "3. Arch Linux: sudo pacman -S ffmpeg",
            "4. 或从 https://ffmpeg.org/download.html 下载静态编译版",
            "5. 打开终端，输入 ffmpeg -version 验证",
        }},
    };
#endif
}

std::string formatCheckReport(const json& cr) {
    std::ostringstream oss;
    oss << "==================================================\n";
    oss << "FFmpeg Environment Check Report\n";
    oss << "==================================================\n";

    auto ff = cr["ffmpeg"];
    if (ff["found"].get<bool>()) {
        oss << "[OK] ffmpeg  : " << ff["path"].get<std::string>() << "\n";
        oss << "             " << ff["version"].get<std::string>() << "\n";
    } else {
        oss << "[MISS] ffmpeg  : not found — " << ff["error"].get<std::string>() << "\n";
    }

    auto fp = cr["ffprobe"];
    if (fp["found"].get<bool>()) {
        oss << "[OK] ffprobe : " << fp["path"].get<std::string>() << "\n";
        oss << "             " << fp["version"].get<std::string>() << "\n";
    } else {
        oss << "[MISS] ffprobe : not found — " << fp["error"].get<std::string>() << "\n";
    }

    if (!cr["all_ok"].get<bool>()) {
        auto guide = getInstallGuide();
        oss << "\nDownload: " << guide["download_url"].get<std::string>() << "\n";
    }
    return oss.str();
}

} // namespace ffmpegpp
