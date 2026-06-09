#include "installer.h"
#include "subprocess.h"
#include <windows.h>
#include <filesystem>
#include <sstream>

namespace ffmpegpp {

namespace fs = std::filesystem;

namespace {
std::string findExecutable(const std::string& name) {
    // 1. 检查 PATH
    char buf[MAX_PATH];
    DWORD len = SearchPathA(nullptr, name.c_str(), ".exe", MAX_PATH, buf, nullptr);
    if (len > 0 && len < MAX_PATH) return std::string(buf);

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
}

ToolCheck checkTool(const std::string& name) {
    ToolCheck result;
    result.path = findExecutable(name);
    if (result.path.empty()) {
        result.error = name + " 未在 PATH 或常见安装目录中找到";
        return result;
    }
    auto pr = Subprocess::run({name, "-version"}, 10);
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

json ensureFFmpeg() {
    auto ff = findFFmpeg();
    auto fp = findFFprobe();
    return {
        {"ffmpeg", {{"found", ff.found}, {"path", ff.path}, {"version", ff.version}, {"error", ff.error}}},
        {"ffprobe", {{"found", fp.found}, {"path", fp.path}, {"version", fp.version}, {"error", fp.error}}},
        {"all_ok", ff.found && fp.found},
    };
}

json getInstallGuide() {
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
