#include "probe.h"
#include "subprocess.h"
#include <cmath>
#include <sstream>
#include <algorithm>

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
    std::transform(ct.begin(), ct.end(), ct.begin(), ::tolower);
    std::transform(cs.begin(), cs.end(), cs.begin(), ::tolower);
    std::vector<std::string> indicators = {"smpte2084", "arib-std-b67", "bt2020"};
    for (const auto& ind : indicators) {
        if (ct.find(ind) != std::string::npos || cs.find(ind) != std::string::npos)
            return true;
    }
    return false;
}

std::string formatDuration(double seconds) {
    if (seconds <= 0) return "00:00:00";
    int total = (int)seconds;
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
        "ffprobe", "-v", "quiet", "-print_format", "json",
        "-show_format", "-show_streams", filepath
    };
    auto pr = Subprocess::run(cmd, 60);
    if (pr.exit_code != 0) {
        result.error = "ffprobe 执行失败: " + pr.stderr_output;
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
        for (auto& s : streams) {
            std::string type = s.value("codec_type", "");
            if (type == "video" && video.is_null()) video = s;
            else if (type == "audio" && audio.is_null()) audio = s;
            else if (type == "subtitle") {
                auto tags = s.value("tags", json::object());
                auto disp = s.value("disposition", json::object());
                subtitles.push_back({
                    {"index", s.value("index", 0)},
                    {"codec", s.value("codec_name", "N/A")},
                    {"language", tags.value("language", "N/A")},
                    {"title", tags.value("title", "N/A")},
                    {"forced", disp.value("forced", 0) == 1},
                    {"default", disp.value("default", 0) == 1},
                });
            }
        }

        if (video.is_null()) {
            result.error = "未检测到视频流";
            return result;
        }

        int64_t format_size = format.value("size", "0") == "0" ? 0 :
            (int64_t)std::stoll(format.value("size", "0"));
        double format_duration = std::stod(format.value("duration", "0.0"));

        result.info = {
            {"filename", filepath.substr(filepath.find_last_of("/\\") + 1)},
            {"filepath", filepath},
            {"format", format.value("format_name", "N/A")},
            {"format_long_name", format.value("format_long_name", "N/A")},
            {"size", format_size},
            {"size_mb", std::round(format_size / (1024.0 * 1024.0) * 100.0) / 100.0},
            {"duration", format_duration},
            {"duration_str", formatDuration(format_duration)},
            {"bit_rate", std::stoi(format.value("bit_rate", "0"))},
            {"bit_rate_kbps", std::round(std::stoi(format.value("bit_rate", "0")) / 1000.0 * 100.0) / 100.0},
            {"codec", video.value("codec_name", "N/A")},
            {"codec_long_name", video.value("codec_long_name", "N/A")},
            {"profile", video.value("profile", "N/A")},
            {"width", video.value("width", 0)},
            {"height", video.value("height", 0)},
            {"resolution", std::to_string(video.value("width", 0)) + "x" + std::to_string(video.value("height", 0))},
            {"pix_fmt", video.value("pix_fmt", "N/A")},
            {"fps", parseFps(video)},
            {"is_hdr", detectHdr(video)},
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
        result.info = {
            {"filename", filepath.substr(filepath.find_last_of("/\\") + 1)},
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
