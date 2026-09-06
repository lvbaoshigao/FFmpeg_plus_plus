#include "probe.h"
#include "subprocess.h"
#include "installer.h"
#include <cmath>
#include <algorithm>
#include <cctype>
#include <signal.h>

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
    // 导入探测只需基本流信息，不需完整 deep analysis。
    // 限制：
    //   -probesize 5MB（旧值 50MB）：mobile 上 ffprobe 解码 50MB codec headers
    //     慢且吃内存；导入阶段只需识别 codec，不需完整帧头解析。
    //   -analyzeduration 10s（旧值 100s）：用户导入时基本 5-10s 即可识别流类型
    //     与 codec，长视频继续 deep analyze 也没必要。
    //   -show_entries 限制输出：避免 ffprobe 把所有 side data / chapter list /
    //     全 stream tags 都打印出来。对 1GB 视频这个 JSON 可能 10MB+。
    //     限制后输出控制在 2-5KB，Dart 端 jsonDecode 也快很多。
    std::vector<std::string> cmd = {
        getFFprobePath(), "-v", "quiet", "-print_format", "json",
        "-probesize", "5000000", "-analyzeduration", "10000000",
        "-show_entries",
        "format=format_name,format_long_name,size,duration,bit_rate:"
        "stream=index,codec_type,codec_name,codec_long_name,profile,"
        "width,height,pix_fmt,nb_frames,avg_frame_rate,r_frame_rate,"
        "color_space,color_transfer,color_primaries,sample_aspect_ratio,"
        "channels,channel_layout,sample_rate",
        "-show_entries", "stream_disposition=forced,default",
        "-show_format", filepath
    };
    auto pr = Subprocess::run(cmd, 240);
    if (pr.output_truncated) {
        // 子进程输出超过 kMaxOutputBytes（16MB）被 Subprocess 强制 kill；
        // 典型情况：用户用过大 probesize/analyzeduration 或让 ffprobe 完整
        // -show_streams（未经 -show_entries 过滤）。直接给清晰错误。
        result.error = std::string("ffprobe 输出过大（>16MB），可能是损坏/超长/"
                                "非标视频，建议用 ffmpeg 重新转一次或联系开发者");
        return result;
    }
    if (pr.exit_code != 0) {
        // exit_code 解释：
        //  - 127  = execvp 失败（命令未找到，如 ffprobe 路径未配置）
        //  - 负值 = 子进程被信号 N 终止（Subprocess 已用 -N 传递，N 即信号编号）
        //           -11=SIGSEGV（段错误，常因 Android 上 jniLibs 二进制不兼容）
        //           -6 =SIGABRT、-9=SIGKILL、-8=SIGFPE 等
        //  - 其他 = ffprobe 自身返回了非 0 退出码（解码错误、格式不支持等）
        std::string detail;
        if (pr.exit_code == 127) {
            detail = "ffprobe 未找到或无法执行，请检查内置工具路径是否正确配置";
        } else if (pr.exit_code < 0) {
            // 信号终止：明确提示信号名，便于排查"ffprobe 自身崩溃"这种问题
            int sig = -pr.exit_code;
            const char* sig_name = "UNKNOWN";
            switch (sig) {
                case SIGSEGV: sig_name = "SIGSEGV"; break;
                case SIGABRT: sig_name = "SIGABRT"; break;
#ifdef SIGBUS
                case SIGBUS:  sig_name = "SIGBUS";  break;
#endif
                case SIGFPE:  sig_name = "SIGFPE";  break;
                case SIGILL:  sig_name = "SIGILL";  break;
#ifdef SIGKILL
                case SIGKILL: sig_name = "SIGKILL"; break;
#endif
                case SIGTERM: sig_name = "SIGTERM"; break;
#ifdef SIGSYS
                case SIGSYS:  sig_name = "SIGSYS";  break;
#endif
                default: break;
            }
            // Android 11+ 上常见：ffprobe 二进制与 nativeLibraryDir 不兼容，
            // 一启动就段错误；务必告知用户去找开发者修，而不是去检查路径/权限。
            detail = std::string("ffprobe 被信号终止 (") + sig_name +
                     ")，通常是 ffprobe 二进制与当前 Android 系统不兼容（常见于 "
                     "nativeLibraryDir 上的静态 PIE 可执行文件无法加载），"
                     "而不是文件路径或权限问题";
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

        // ffprobe 对某些容器会输出 "N/A"，std::stod/stoll 直接抛异常导致整个
        // 探测失败，因此全部 try 包裹、失败回退 0（与上面 bit_rate 同样处理）。
        std::string size_str = format.value("size", "0");
        int64_t format_size = 0;
        try { format_size = std::stoll(size_str); } catch (...) {}
        double format_duration = 0.0;
        try { format_duration = std::stod(format.value("duration", "0.0")); } catch (...) {}

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

} // namespace ffmpegpp
