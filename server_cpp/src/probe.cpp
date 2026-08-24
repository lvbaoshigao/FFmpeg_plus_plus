#include "probe.h"
#include "subprocess.h"
#include "installer.h"
#include <cmath>
#include <sstream>
#include <algorithm>
#include <cctype>

namespace ffmpegpp {

namespace {

double parseFps(const json& stream) {
    for (const auto& key : {"r_frame_rate", "avg_frame_rate"}) {
        if (stream.contains(key)) {
            std::string fps_str = stream[key].get<std::string>();
            auto slash = fps_str.find('/');
            if (slash != std::string::npos) {
                try {
                    double num = std::stod(fps_str.substr(0, slash));
                    double den = std::stod(fps_str.substr(slash + 1));
                    if (den > 0) return std::round(num / den * 100.0) / 100.0;
                } catch (...) {}
            } else {
                try { return std::stod(fps_str); } catch (...) {}
            }
        }
    }
    return 0.0;
}

bool detectHdr(const json& stream) {
    std::string ct = stream.value("color_transfer", "");
    std::string cs = stream.value("color_space", "");
    std::transform(ct.begin(), ct.end(), ct.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    std::transform(cs.begin(), cs.end(), cs.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    std::vector<std::string> indicators = {"smpte2084", "arib-std-b67", "bt2020"};
    for (const auto& ind : indicators) {
        if (ct.find(ind) != std::string::npos || cs.find(ind) != std::string::npos)
            return true;
    }
    return false;
}

std::string formatDuration(double seconds) {
    if (!std::isfinite(seconds) || seconds <= 0) return "00:00:00";
    // 防止异常时长（inf/nan/极大值）越界强转 int -> UB / 负值时间戳
    const double clamped = std::min(seconds, 359999.0);
    int total = (int)clamped;
    int h = total / 3600;
    int m = (total % 3600) / 60;
    int s = total % 60;
    char buf[16];
    snprintf(buf, sizeof(buf), "%02d:%02d:%02d", h, m, s);
    return buf;
}

} // namespace

ProbeResult probeFile(const std::string& filepath) {
    ProbeResult result;
    std::vector<std::string> cmd = {
        getFFprobePath(), "-v", "quiet", "-print_format", "json",
        "-probesize", "50000000", "-analyzeduration", "100000000",
        "-show_format", "-show_streams", filepath
    };
    auto pr = Subprocess::run(cmd, 120);
    if (pr.exit_code != 0) {
        // exit_code 127 = execvp 失败（命令未找到，如 ffprobe 路径未配置）
        // exit_code 其他 = ffprobe 运行失败
        std::string detail;
        if (pr.exit_code == 127) {
            detail = "ffprobe 未找到或无法执行，请检查内置工具路径是否正确配置";
        } else if (pr.stderr_output.empty()) {
            detail = "无法读取文件，请检查路径或文件权限";
        } else {
            detail = pr.stderr_output.substr(0, 200);
        }
        result.error = "ffprobe 执行失败 (" + std::to_string(pr.exit_code) + "): " + detail;
        return result;
    }
    try {
        result.info = json::parse(pr.stdout_output);
        result.success = true;
    } catch (const std::exception& e) {
        result.error = std::string("ffprobe JSON 解析失败: ") + e.what();
    }
    return result;
}

ProbeResult probeVideo(const std::string& filepath) {
    auto raw = probeFile(filepath);
    if (!raw.success) return raw;

    ProbeResult result;
    try {
        auto& data = raw.info;
        auto format = data.value("format", json::object());
        auto streams = data.value("streams", json::array());

        json video, audio;
        json subtitles = json::array();
        int sub_counter = 0;  // 字幕流序号（si 参数用，从 0 开始）
        for (auto& s : streams) {
            std::string type = s.value("codec_type", "");
            if (type == "video" && video.is_null()) video = s;
            else if (type == "audio" && audio.is_null()) audio = s;
            else if (type == "subtitle") {
                auto tags = s.value("tags", json::object());
                auto disp = s.value("disposition", json::object());
                subtitles.push_back({
                    {"index", sub_counter},       // 字幕流序号（si 用）
                    {"stream_index", s.value("index", 0)},  // 全局流索引（仅供参考）
                    {"codec", s.value("codec_name", "N/A")},
                    {"language", tags.value("language", "N/A")},
                    {"title", tags.value("title", "N/A")},
                    {"forced", disp.value("forced", 0) == 1},
                    {"default", disp.value("default", 0) == 1},
                });
                sub_counter++;
            }
        }

        if (video.is_null() && audio.is_null()) {
            result.error = "未检测到视频或音频流";
            return result;
        }

        std::string size_str = format.value("size", "0");
        int64_t format_size = (size_str == "0") ? 0 : (int64_t)std::stoll(size_str);
        double format_duration = std::stod(format.value("duration", "0.0"));

        // 检测文件媒体类型：video / audio / image
        std::string media_type = "video";
        if (video.is_null()) {
            media_type = "audio";
        } else if (format_duration <= 0.1 || video.value("nb_frames", "0") == "1") {
            media_type = "image";
        }

        auto sep_pos = filepath.find_last_of("/\\");
        std::string bit_rate_str = format.value("bit_rate", "0");
        long long bit_rate = 0;
        try { bit_rate = std::stoll(bit_rate_str); } catch (...) {}
        result.info = {
            {"filename", (sep_pos != std::string::npos) ? filepath.substr(sep_pos + 1) : filepath},
            {"filepath", filepath},
            {"media_type", media_type},
            {"format", format.value("format_name", "N/A")},
            {"format_long_name", format.value("format_long_name", "N/A")},
            {"size", format_size},
            {"size_mb", std::round(format_size / (1024.0 * 1024.0) * 100.0) / 100.0},
            {"duration", format_duration},
            {"duration_str", formatDuration(format_duration)},
            {"bit_rate", bit_rate},
            {"bit_rate_kbps", std::round(bit_rate / 1000.0 * 100.0) / 100.0},
            {"codec", video.is_null() ? "N/A" : video.value("codec_name", "N/A")},
            {"codec_long_name", video.is_null() ? "N/A" : video.value("codec_long_name", "N/A")},
            {"profile", video.is_null() ? "N/A" : video.value("profile", "N/A")},
            {"width", video.is_null() ? 0 : video.value("width", 0)},
            {"height", video.is_null() ? 0 : video.value("height", 0)},
            {"resolution", video.is_null() ? "N/A" : std::to_string(video.value("width", 0)) + "x" + std::to_string(video.value("height", 0))},
            {"pix_fmt", video.is_null() ? "N/A" : video.value("pix_fmt", "N/A")},
            {"fps", video.is_null() ? 0.0 : parseFps(video)},
            {"is_hdr", video.is_null() ? false : detectHdr(video)},
            {"audio_codec", audio.is_null() ? "N/A" : audio.value("codec_name", "N/A")},
            {"audio_channels", audio.is_null() ? 0 : audio.value("channels", 0)},
            {"audio_sample_rate", audio.is_null() ? "N/A" : audio.value("sample_rate", "N/A")},
            {"has_subtitles", !subtitles.empty()},
            {"subtitle_count", (int)subtitles.size()},
            {"subtitles", subtitles},
        };
        result.success = true;
    } catch (const std::exception& e) {
        result.error = std::string("解析视频信息时出错: ") + e.what();
    }
    return result;
}

ProbeResult probeSubtitle(const std::string& filepath) {
    auto raw = probeFile(filepath);
    if (!raw.success) return raw;

    ProbeResult result;
    try {
        auto& data = raw.info;
        auto format = data.value("format", json::object());
        auto streams = data.value("streams", json::array());
        if (streams.empty()) { result.error = "未检测到字幕流"; return result; }

        auto stream = streams[0];
        auto tags = stream.value("tags", json::object());
        auto sep_pos = filepath.find_last_of("/\\");
        result.info = {
            {"filename", (sep_pos != std::string::npos) ? filepath.substr(sep_pos + 1) : filepath},
            {"filepath", filepath},
            {"format", format.value("format_name", "N/A")},
            {"codec", stream.value("codec_name", "N/A")},
            {"codec_long_name", stream.value("codec_long_name", "N/A")},
            {"language", tags.value("language", "N/A")},
        };
        result.success = true;
    } catch (const std::exception& e) {
        result.error = std::string("解析字幕信息时出错: ") + e.what();
    }
    return result;
}

} // namespace ffmpegpp
