#include "subtitle.h"
#include "constants.h"
#include "transcoder.h"
#include "probe.h"
#include "installer.h"
#include <stdexcept>
#include <sstream>
#include <algorithm>

namespace ffmpegpp {

namespace {
std::string escapeFilterPath(const std::string& filepath) {
    std::string p = filepath;
#ifdef _WIN32
    std::replace(p.begin(), p.end(), '\\', '/');
#endif
    std::string result;
    for (size_t i = 0; i < p.size(); ++i) {
        char c = p[i];
        if (c == ':' || c == '\'' || c == '\\' || c == '[' || c == ']'
                   || c == ';' || c == ',' || c == '=' || c == '%') {
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
    // 严格验证：只允许十六进制字符
    for (char c : h) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
            throw std::runtime_error("颜色值包含非法字符");
    }
    // 8 位 ARGB(#AARRGGBB) → ASS &HAABBGGRR&：高位 alpha，之后 B、G、R
    if (h.size() >= 8) {
        return "&H" + h.substr(0, 2) + h.substr(6, 2) + h.substr(4, 2) + h.substr(2, 2) + "&";
    }
    // 6 位 RGB → ASS BGR 格式 (&HBBGGRR&)
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
        if (!isPathSafe(sub_file)) throw std::runtime_error("字幕路径包含不安全字符");
        filter << "subtitles='" << escapeFilterPath(sub_file) << "'";
    } else if (source == "embedded") {
        // 类型安全检查
        if (!opts.contains("subtitle_index")) {
            throw std::runtime_error("内嵌字幕模式需要提供 subtitle_index");
        }
        int sub_index;
        try {
            sub_index = opts["subtitle_index"].get<int>();
        } catch (...) {
            throw std::runtime_error("subtitle_index 必须是整数");
        }
        if (sub_index < 0) {
            throw std::runtime_error("subtitle_index 必须为非负整数");
        }
        filter << "subtitles='" << escapeFilterPath(input_path) << "':si=" << sub_index;
    } else {
        throw std::runtime_error("未知字幕来源: " + source);
    }

    // 样式
    if (opts.contains("style") && !opts["style"].is_null()) {
        auto& style = opts["style"];
        if (!style.is_object()) {
            throw std::runtime_error("style 必须是对象");
        }
        std::vector<std::string> parts;
        if (style.contains("font_name") && !style["font_name"].is_null()) {
            std::string fn;
            try {
                fn = style["font_name"].get<std::string>();
            } catch (...) {
                throw std::runtime_error("font_name 必须是字符串");
            }
            // 字体名仅允许字母、数字、空格、连字符、下划线和中文
            bool fn_safe = true;
            for (char c : fn) {
                if (c == ';' || c == '\'' || c == '"' || c == '\\' || c == '|'
                    || c == '`' || c == '$' || c == '\n' || c == '\r'
                    || c == ',' || c == '=' || c == '[' || c == ']') {
                    fn_safe = false;
                    break;
                }
            }
            if (!fn_safe) throw std::runtime_error("字体名包含不安全字符");
            parts.push_back("FontName=" + fn);
        }
        if (style.contains("font_size") && !style["font_size"].is_null()) {
            int font_size;
            try {
                font_size = style["font_size"].get<int>();
            } catch (...) {
                throw std::runtime_error("font_size 必须是整数");
            }
            if (font_size <= 0 || font_size > 1000) {
                throw std::runtime_error("font_size 必须在 1-1000 之间");
            }
            parts.push_back("FontSize=" + std::to_string(font_size));
        }
        if (style.contains("font_color") && !style["font_color"].is_null()) {
            std::string font_color;
            try {
                font_color = style["font_color"].get<std::string>();
            } catch (...) {
                throw std::runtime_error("font_color 必须是字符串");
            }
            parts.push_back("PrimaryColour=" + hexToASS(font_color));
        }
        if (style.contains("outline_width") && !style["outline_width"].is_null()) {
            int outline_width;
            try {
                outline_width = style["outline_width"].get<int>();
            } catch (...) {
                throw std::runtime_error("outline_width 必须是整数");
            }
            if (outline_width < 0 || outline_width > 20) {
                throw std::runtime_error("outline_width 必须在 0-20 之间");
            }
            parts.push_back("Outline=" + std::to_string(outline_width));
        }
        if (style.contains("outline_color") && !style["outline_color"].is_null()) {
            std::string outline_color;
            try {
                outline_color = style["outline_color"].get<std::string>();
            } catch (...) {
                throw std::runtime_error("outline_color 必须是字符串");
            }
            parts.push_back("OutlineColour=" + hexToASS(outline_color));
        }

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
    const json& video_options,
    std::string input_pix_fmt /* = "" */) {

    // ── 输入/输出路径安全检查 ──
    if (!isPathSafe(input_path))
        throw std::runtime_error("输入路径包含不安全字符");
    if (!isPathSafe(output_path))
        throw std::runtime_error("输出路径包含不安全字符");

    std::vector<std::string> cmd = {getFFmpegPath(), "-i", input_path};

    // 构建视频滤镜链：先追加外部 vf_filters（如 setpts），再追加字幕滤镜
    std::string sub_filter = buildSubtitleFilter(input_path, subtitle_options);
    std::string vf = sub_filter;
    if (!video_options.is_null() && video_options.contains("vf_filters") &&
        video_options["vf_filters"].is_array() && !video_options["vf_filters"].empty()) {
        std::string prefix;
        for (auto& f : video_options["vf_filters"]) {
            if (!f.is_string()) {
                throw std::runtime_error("vf_filters 中的元素必须是字符串");
            }
            std::string fs = f.get<std::string>();
            if (!isFilterSafe(fs))
                throw std::runtime_error("视频滤镜包含不安全内容: " + fs);
            if (!prefix.empty()) prefix += ",";
            prefix += fs;
        }
        vf = prefix + "," + sub_filter;
    }
    cmd.push_back("-vf");
    cmd.push_back(vf);

    // 音频滤镜（如变速 atempo）
    if (!video_options.is_null() && video_options.contains("af_filters") &&
        video_options["af_filters"].is_array() && !video_options["af_filters"].empty()) {
        std::string af;
        for (auto& f : video_options["af_filters"]) {
            if (!f.is_string()) {
                throw std::runtime_error("af_filters 中的元素必须是字符串");
            }
            std::string fs = f.get<std::string>();
            if (!isFilterSafe(fs))
                throw std::runtime_error("音频滤镜包含不安全内容: " + fs);
            if (!af.empty()) af += ",";
            af += fs;
        }
        cmd.push_back("-af");
        cmd.push_back(af);
    }

    // 视频+音频编码（烧录字幕必须重新编码）
    json vopts;
    if (!video_options.is_null() && video_options.is_object()) {
        vopts = video_options;
    } else {
        vopts = {{"video_codec", "h264"}, {"gpu", "CPU"}, {"preset", "medium"}, {"video_bitrate", 2000}};
    }

    // 探测源像素格式，自动选择输出格式（保留 10-bit）；调用方已探测时复用
    if (input_pix_fmt.empty()) {
        try {
            auto probe = probeVideo(input_path);
            if (probe.success) {
                input_pix_fmt = probe.info.value("pix_fmt", "");
            }
        } catch (...) {}
    }

    auto enc_params = buildEncodingParams(vopts, input_pix_fmt);
    cmd.insert(cmd.end(), enc_params.begin(), enc_params.end());

    cmd.push_back("-y");
    cmd.push_back(output_path);
    return cmd;
}

} // namespace ffmpegpp
