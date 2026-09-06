#pragma once
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <cctype>

namespace ffmpegpp {

// GPU 编码器映射
inline std::map<std::string, std::map<std::string, std::string>> GPU_ENCODERS = {
    {"CPU", {{"h264", "libx264"}, {"h265", "libx265"}, {"vp9", "libvpx-vp9"}}},
    {"NVIDIA", {{"h264", "h264_nvenc"}, {"h265", "hevc_nvenc"}, {"av1", "av1_nvenc"}}},
    {"AMD", {{"h264", "h264_amf"}, {"h265", "hevc_amf"}, {"av1", "av1_amf"}}},
    {"Intel", {{"h264", "h264_qsv"}, {"h265", "hevc_qsv"}, {"av1", "av1_qsv"}}},
    // Android：内置 ffmpeg 以 --enable-mediacodec 构建，硬编走 NDK MediaCodec
    //（无需 JVM/Surface，buffer 模式输出标准 AnnexB → 由 ffmpeg 封装为 mp4）。
    {"Android", {{"h264", "h264_mediacodec"}, {"h265", "hevc_mediacodec"}}},
};

// ═══════════════════════════════════════════════
// 输入校验
// ═══════════════════════════════════════════════

// 检查文件路径是否包含危险字符（防止命令注入）
inline bool isPathSafe(const std::string& path) {
    if (path.empty()) return false;
    // 禁止 UNC 路径（防止 NTLM 凭证泄漏）
    if (path.size() >= 2 && path[0] == '\\' && path[1] == '\\') return false;
    if (path.size() >= 2 && path[0] == '/' && path[1] == '/') return false;
    for (char c : path) {
        if (c == '|' || c == '`' || c == '$' || c == '\n' || c == '\r' || c == '\0')
            return false;
    }
    // 禁止路径穿越（/../ 或 \..\ 或开头的 ../ ..\）
    if (path.find("/../") != std::string::npos || path.find("\\..\\") != std::string::npos) return false;
    if (path.find("/..\\") != std::string::npos || path.find("\\../") != std::string::npos) return false;
    if (path.size() >= 3 && path.substr(0, 3) == "../") return false;
    if (path.size() >= 3 && path.substr(0, 3) == "..\\") return false;
    if (path == "..") return false;
    return true;
}

// 允许的 preset 值白名单
inline std::vector<std::string> VALID_PRESETS = {
    "ultrafast", "superfast", "veryfast", "faster", "fast",
    "medium", "slow", "slower", "veryslow", "placebo",
    "default", "hp", "hq", "bd", "ll", "llhq", "llhp", "lossless", "losslesshp",
    "speed", "quality", "balanced",
};

// 允许的像素格式白名单
inline std::vector<std::string> VALID_PIX_FMTS = {
    "yuv420p", "yuv422p", "yuv444p", "nv12", "nv21",
    "yuv420p10le", "yuv422p10le", "yuv444p10le",
    "p010le", "rgb24", "bgr24", "rgba", "bgra",
    "gray", "gray16le",
};

// 允许的音频编码器白名单
inline std::vector<std::string> VALID_AUDIO_CODECS = {
    "aac", "libmp3lame", "libopus", "flac", "libfdk_aac",
    "ac3", "eac3", "pcm_s16le", "pcm_s24le", "pcm_s32le",
    "pcm_f32le", "vorbis", "libvorbis", "wmav2", "copy", "",
};

// 禁止的 ffmpeg 过滤器名（可读写文件或执行命令的危险过滤器）
inline std::vector<std::string> DANGEROUS_FILTERS = {
    "movie", "amovie", "sendcmd", "zmq", "program",
    "azmq", "coreimage", "testsrc", "life", "cellauto",
    "opencl", "opengl", "libplacebo",
    // drawtext 支持 textfile= 读取任意文件内容并绘制进画面（信息泄露）
    "drawtext",
    // 字幕/字体滤镜直接读取本地文件内容并烧进画面（信息泄露）
    "subtitles", "ass", "ssa",
    // readfile 读取任意文件内容注入滤镜元数据
    "readfile",
};

// 验证过滤器字符串是否安全
inline bool isFilterSafe(const std::string& filter) {
    std::string lower = filter;
    // 用 unsigned char 转型，避免 UTF-8 高位字节（有符号负值）传给 tolower 触发 UB
    std::transform(lower.begin(), lower.end(), lower.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

    // 禁止 shell 元字符
    for (char c : filter) {
        if (c == '|' || c == '`' || c == '$' || c == '\n' || c == '\r')
            return false;
    }

    for (auto& df : DANGEROUS_FILTERS) {
        size_t pos = 0;
        while ((pos = lower.find(df, pos)) != std::string::npos) {
            // 确认是独立的过滤器名：前面是行首或分隔符（含 ] 用于滤镜图标签）
            bool prefix_ok = (pos == 0 || lower[pos - 1] == ',' || lower[pos - 1] == ';'
                              || lower[pos - 1] == ' ' || lower[pos - 1] == ']');
            // 后面是行尾、= 或分隔符
            size_t end = pos + df.size();
            bool suffix_ok = (end >= lower.size() || lower[end] == '=' || lower[end] == ','
                              || lower[end] == ';' || lower[end] == ' ' || lower[end] == '[');
            if (prefix_ok && suffix_ok) {
                return false;
            }
            pos += df.size();
        }
    }
    return true;
}

// 验证字符串值是否在白名单中
inline bool isInWhitelist(const std::string& value, const std::vector<std::string>& whitelist) {
    for (auto& w : whitelist) {
        if (w == value) return true;
    }
    return false;
}

} // namespace ffmpegpp
