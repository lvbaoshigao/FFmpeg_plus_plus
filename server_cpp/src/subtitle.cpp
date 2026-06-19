#include "subtitle.h"
#include "constants.h"
#include "transcoder.h"
#include "probe.h"
#include <stdexcept>
#include <sstream>
#include <algorithm>

namespace ffmpegpp {

namespace {
std::string escapeFilterPath(const std::string& filepath) {
    std::string p = filepath;
    // 反斜杠 → 正斜杠
    std::replace(p.begin(), p.end(), '\\', '/');
    // 转义 ffmpeg 滤镜路径中的特殊字符
    std::string result;
    for (size_t i = 0; i < p.size(); ++i) {
        char c = p[i];
        if (c == ':' && i == 1) {
            // 盘符冒号（如 J:）→ \:
            result += "\\:";
        } else if (c == '\'' || c == '\\' || c == '[' || c == ']') {
            // 单引号、反斜杠、方括号 → 前缀反斜杠
            result += '\\';
            result += c;
        } else {
            result += c;
        }
    }
    return result;
}

std::string hexToASS(const std::string& hex) {
    std::string h = hex;
    if (!h.empty() && h[0] == '#') h = h.substr(1);
    // RGB → ASS BGR 格式 (&HBBGGRR&)
    if (h.size() >= 6) {
        return "&H" + h.substr(4, 2) + h.substr(2, 2) + h.substr(0, 2) + "&";
    }
    return "&H" + h + "&";
}
} // namespace

std::string buildSubtitleFilter(const std::string& input_path, const json& opts) {
    std::string source = opts.value("source", "external");
    std::ostringstream filter;

    if (source == "external") {
        std::string sub_file = opts.value("subtitle_file", "");
        if (sub_file.empty()) throw std::runtime_error("外挂字幕模式需要提供 subtitle_file");
        filter << "subtitles='" << escapeFilterPath(sub_file) << "'";
    } else if (source == "embedded") {
        int sub_index = opts.value("subtitle_index", 0);
        filter << "subtitles='" << escapeFilterPath(input_path) << "':si=" << sub_index;
    } else {
        throw std::runtime_error("未知字幕来源: " + source);
    }

    // 样式
    if (opts.contains("style") && !opts["style"].is_null()) {
        auto& style = opts["style"];
        std::vector<std::string> parts;
        if (style.contains("font_name") && !style["font_name"].is_null())
            parts.push_back("FontName=" + style["font_name"].get<std::string>());
        if (style.contains("font_size") && !style["font_size"].is_null())
            parts.push_back("FontSize=" + std::to_string(style["font_size"].get<int>()));
        if (style.contains("font_color") && !style["font_color"].is_null())
            parts.push_back("PrimaryColour=" + hexToASS(style["font_color"].get<std::string>()));
        if (style.contains("outline_width") && !style["outline_width"].is_null())
            parts.push_back("Outline=" + std::to_string(style["outline_width"].get<int>()));
        if (style.contains("outline_color") && !style["outline_color"].is_null())
            parts.push_back("OutlineColour=" + hexToASS(style["outline_color"].get<std::string>()));

        if (!parts.empty()) {
            filter << ":force_style='";
            for (size_t i = 0; i < parts.size(); ++i) {
                if (i > 0) filter << ",";
                filter << parts[i];
            }
            filter << "'";
        }
    }

    return filter.str();
}

std::vector<std::string> buildSubtitleCommand(
    const std::string& input_path,
    const std::string& output_path,
    const json& subtitle_options,
    const json& video_options) {

    std::vector<std::string> cmd = {"ffmpeg", "-i", input_path};

    // 字幕滤镜
    std::string sub_filter = buildSubtitleFilter(input_path, subtitle_options);
    cmd.push_back("-vf");
    cmd.push_back(sub_filter);

    // 视频+音频编码（烧录字幕必须重新编码）
    json vopts;
    if (!video_options.is_null() && video_options.is_object()) {
        vopts = video_options;
    } else {
        vopts = {{"video_codec", "h264"}, {"gpu", "CPU"}, {"preset", "medium"}, {"video_bitrate", 2000}};
    }

    // 探测源像素格式，自动选择输出格式（保留 10-bit）
    std::string input_pix_fmt;
    try {
        auto probe = probeVideo(input_path);
        if (probe.success) {
            input_pix_fmt = probe.info.value("pix_fmt", "");
        }
    } catch (...) {}

    auto enc_params = buildEncodingParams(vopts, input_pix_fmt);
    cmd.insert(cmd.end(), enc_params.begin(), enc_params.end());

    cmd.push_back("-y");
    cmd.push_back(output_path);
    return cmd;
}

} // namespace ffmpegpp
