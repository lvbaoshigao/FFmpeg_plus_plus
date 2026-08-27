#include "transcoder.h"
#include "probe.h"
#include "constants.h"
#include "installer.h"
#include <stdexcept>

namespace ffmpegpp {

// 根据编码器、编码格式和源像素格式，选择正确的输出像素格式
// H.264 编码器（libx264/h264_nvenc/h264_amf/h264_qsv）：不支持 10-bit
// H.265 编码器：libx265 支持 yuv420p10le，硬件编码器支持 p010le
static std::string resolvePixFmt(const std::string& encoder, const std::string& codec_key, const std::string& input_pix_fmt) {
    bool is10bit = (input_pix_fmt.find("10") != std::string::npos);

    // Android MediaCodec 硬编：接受 nv12（8-bit）/ p010le（10-bit）输入。
    // 注意必须放在通用 "264" 判断之前，否则 h264_mediacodec 会被当成
    // 普通 x264 走 yuv420p 分支，导致编码器不支持的像素格式报错。
    if (encoder.find("mediacodec") != std::string::npos) {
        return is10bit ? "p010le" : "nv12";
    }

    // H.264 不支持 10-bit，强制降级
    if (codec_key == "h264" || encoder.find("264") != std::string::npos) {
        return "yuv420p";
    }

    // H.265 硬件编码器
    if (encoder.find("nvenc") != std::string::npos ||
        encoder.find("amf") != std::string::npos ||
        encoder.find("qsv") != std::string::npos) {
        return is10bit ? "p010le" : "nv12";
    }

    // libx265：支持 10-bit
    if (encoder == "libx265") {
        if (is10bit) {
            if (input_pix_fmt.find("422") != std::string::npos) return "yuv422p10le";
            if (input_pix_fmt.find("444") != std::string::npos) return "yuv444p10le";
            return "yuv420p10le";
        }
        return "yuv420p";
    }

    // 其他编码器：默认 8-bit
    return "yuv420p";
}

std::string resolveEncoder(const std::string& gpu, const std::string& codec_key) {
    if (codec_key == "copy") return "copy";

    // 通过 GPU_ENCODERS 映射
    if (GPU_ENCODERS.count(gpu) && GPU_ENCODERS.at(gpu).count(codec_key))
        return GPU_ENCODERS.at(gpu).at(codec_key);
    if (GPU_ENCODERS.count("CPU") && GPU_ENCODERS.at("CPU").count(codec_key))
        return GPU_ENCODERS.at("CPU").at(codec_key);

    // 直接使用原始编码器名
    static std::vector<std::string> valid = {
        "libx264", "h264_amf", "h264_nvenc", "h264_qsv", "h264_mediacodec",
        "libx265", "hevc_amf", "hevc_nvenc", "hevc_qsv", "hevc_mediacodec",
        "libaom-av1", "av1_amf", "av1_nvenc", "av1_qsv",
        "libvpx-vp9", "mpeg4", "prores_ks", "ffv1",
        "aac", "libmp3lame", "libopus", "flac", "libfdk_aac",
    };
    for (auto& v : valid) {
        if (v == codec_key) return codec_key;
    }
    throw std::runtime_error("不支持的编码器: " + codec_key);
}

std::vector<std::string> buildEncodingParams(const json& options, const std::string& input_pix_fmt) {
    // 视频编码器类型检查
    std::string video_codec;
    try {
        if (options.contains("video_codec")) {
            const auto& vc = options["video_codec"];
            if (vc.is_null()) {
                video_codec = "h264";
            } else if (vc.is_string()) {
                video_codec = vc.get<std::string>();
            } else {
                throw std::runtime_error("video_codec 必须是字符串");
            }
        } else {
            video_codec = "h264";
        }
    } catch (const std::exception& e) {
        throw std::runtime_error(std::string("video_codec 解析失败: ") + e.what());
    }
    
    std::string gpu = options.value("gpu", "CPU");
    bool has_vf = options.contains("vf_filters") && options["vf_filters"].is_array() && !options["vf_filters"].empty();

    std::vector<std::string> params;

    // video_codec != "none" 才处理视频流（"none" = 纯音频模式）
    if (video_codec != "none") {
        if (has_vf && video_codec == "copy") {
            video_codec = "h264";
        }
        std::string encoder = resolveEncoder(gpu, video_codec);

        params.push_back("-c:v");
        params.push_back(encoder);

        if (options.contains("pix_fmt") && !options["pix_fmt"].is_null()) {
            std::string pf;
            try {
                pf = options["pix_fmt"].get<std::string>();
            } catch (...) {
                throw std::runtime_error("pix_fmt 必须是字符串");
            }
            if (!isInWhitelist(pf, VALID_PIX_FMTS))
                throw std::runtime_error("不支持的像素格式: " + pf);
            params.push_back("-pix_fmt");
            params.push_back(pf);
        } else if (!input_pix_fmt.empty() && encoder != "copy") {
            std::string out_fmt = resolvePixFmt(encoder, video_codec, input_pix_fmt);
            params.push_back("-pix_fmt");
            params.push_back(out_fmt);
        }

        if (options.contains("resolution") && !options["resolution"].is_null()) {
            auto res = options["resolution"];
            if (!res.is_array() || res.size() != 2) {
                throw std::runtime_error("resolution 必须是 [width, height] 数组");
            }
            try {
                int w = res[0].get<int>();
                int h = res[1].get<int>();
                if (w <= 0 || h <= 0) {
                    throw std::runtime_error("分辨率必须为正数");
                }
                params.push_back("-s");
                params.push_back(std::to_string(w) + "x" + std::to_string(h));
            } catch (const std::bad_cast&) {
                throw std::runtime_error("resolution 数组元素必须是整数");
            }
        }

        if (encoder != "copy") {
            if (options.contains("crf") && !options["crf"].is_null()) {
                int crf_val;
                try {
                    crf_val = options["crf"].get<int>();
                } catch (...) {
                    throw std::runtime_error("crf 必须是整数");
                }
                if (encoder.find("nvenc") != std::string::npos) {
                    params.push_back("-cq");
                    params.push_back(std::to_string(crf_val));
                    params.push_back("-rc");
                    params.push_back("vbr");
                } else if (encoder.find("amf") != std::string::npos) {
                    params.push_back("-qp_i");
                    params.push_back(std::to_string(crf_val));
                    params.push_back("-qp_p");
                    params.push_back(std::to_string(crf_val));
                    params.push_back("-rc");
                    params.push_back("cqp");
                } else if (encoder.find("qsv") != std::string::npos) {
                    params.push_back("-global_quality");
                    params.push_back(std::to_string(crf_val));
                } else {
                    params.push_back("-crf");
                    params.push_back(std::to_string(crf_val));
                }
            } else if (options.contains("video_bitrate") && !options["video_bitrate"].is_null()) {
                int bitrate_val;
                try {
                    bitrate_val = options["video_bitrate"].get<int>();
                } catch (...) {
                    throw std::runtime_error("video_bitrate 必须是整数");
                }
                if (bitrate_val <= 0) {
                    throw std::runtime_error("video_bitrate 必须为正数");
                }
                params.push_back("-b:v");
                params.push_back(std::to_string(bitrate_val) + "k");
            }

            if (options.contains("framerate") && !options["framerate"].is_null()) {
                double fps_val;
                try {
                    fps_val = options["framerate"].get<double>();
                } catch (...) {
                    throw std::runtime_error("framerate 必须是数字");
                }
                if (!std::isfinite(fps_val) || fps_val <= 0) {
                    throw std::runtime_error("framerate 必须为正数");
                }
                params.push_back("-r");
                params.push_back(std::to_string(fps_val));
            }

            if (gpu == "CPU" && options.contains("preset")) {
                std::string pr;
                try {
                    pr = options["preset"].get<std::string>();
                } catch (...) {
                    throw std::runtime_error("preset 必须是字符串");
                }
                if (!isInWhitelist(pr, VALID_PRESETS))
                    throw std::runtime_error("不支持的编码预设: " + pr);
                params.push_back("-preset");
                params.push_back(pr);
            }
        }
    }

    // 音频
    std::string audio_codec;
    try {
        audio_codec = options.value("audio_codec", "aac");
    } catch (...) {
        audio_codec = "aac";  // 类型错误时使用默认值
    }
    if (!isInWhitelist(audio_codec, VALID_AUDIO_CODECS))
        throw std::runtime_error("不支持的音频编码器: " + audio_codec);
    bool has_af = options.contains("af_filters") && options["af_filters"].is_array() && !options["af_filters"].empty();
    if (has_af && (audio_codec == "copy" || audio_codec.empty())) {
        audio_codec = "aac";
    }
    if (!audio_codec.empty()) {
        params.push_back("-c:a");
        params.push_back(audio_codec);
        if (audio_codec != "copy") {
            if (options.contains("audio_bitrate") && !options["audio_bitrate"].is_null()) {
                int bitrate_val;
                try {
                    bitrate_val = options["audio_bitrate"].get<int>();
                } catch (...) {
                    throw std::runtime_error("audio_bitrate 必须是整数");
                }
                if (bitrate_val <= 0) {
                    throw std::runtime_error("audio_bitrate 必须为正数");
                }
                params.push_back("-b:a");
                params.push_back(std::to_string(bitrate_val) + "k");
            }
            if (options.contains("sample_rate") && !options["sample_rate"].is_null()) {
                int sample_rate_val;
                try {
                    sample_rate_val = options["sample_rate"].get<int>();
                } catch (...) {
                    throw std::runtime_error("sample_rate 必须是整数");
                }
                if (sample_rate_val <= 0) {
                    throw std::runtime_error("sample_rate 必须为正数");
                }
                params.push_back("-ar");
                params.push_back(std::to_string(sample_rate_val));
            }
        }
        if (options.contains("audio_channels") && !options["audio_channels"].is_null()) {
            int channels_val;
            try {
                channels_val = options["audio_channels"].get<int>();
            } catch (...) {
                throw std::runtime_error("audio_channels 必须是整数");
            }
            if (channels_val <= 0) {
                throw std::runtime_error("audio_channels 必须为正数");
            }
            params.push_back("-ac");
            params.push_back(std::to_string(channels_val));
        }
    } else {
        params.push_back("-c:a");
        params.push_back("copy");
    }

    return params;
}

std::vector<std::string> buildTranscodeCommand(
    const std::string& input_path,
    const std::string& output_path,
    const json& options,
    std::string input_pix_fmt /* = "" */) {

    // 类型安全的参数提取
    std::string gpu;
    try {
        gpu = options.value("gpu", "CPU");
    } catch (...) {
        gpu = "CPU";
    }
    
    std::string video_codec;
    try {
        if (options.contains("video_codec")) {
            if (options["video_codec"].is_null()) {
                video_codec = "h264";
            } else if (options["video_codec"].is_string()) {
                video_codec = options["video_codec"].get<std::string>();
            } else {
                throw std::runtime_error("video_codec 必须是字符串");
            }
        } else {
            video_codec = "h264";
        }
    } catch (const std::exception& e) {
        throw std::runtime_error(std::string("video_codec 解析失败: ") + e.what());
    }
    bool audio_only = (video_codec == "none");

    // 探测源文件像素格式（纯音频模式跳过）；调用方已探测时直接复用，避免重复启动 ffprobe
    if (input_pix_fmt.empty() && !audio_only) {
        try {
            auto probe = probeVideo(input_path);
            if (probe.success) {
                input_pix_fmt = probe.info.value("pix_fmt", "");
            }
        } catch (...) {}
    }

    std::vector<std::string> cmd = {getFFmpegPath()};

    // ── 输入/输出路径安全检查 ──
    if (!isPathSafe(input_path))
        throw std::runtime_error("输入路径包含不安全字符");
    if (!isPathSafe(output_path))
        throw std::runtime_error("输出路径包含不安全字符");

    // 片段截取：-ss 放在 -i 之前（input seeking，更快）
    if (options.contains("start_time") && !options["start_time"].is_null()) {
        double start_time;
        try {
            start_time = options["start_time"].get<double>();
        } catch (...) {
            throw std::runtime_error("start_time 必须是数字");
        }
        if (!std::isfinite(start_time) || start_time < 0) {
            throw std::runtime_error("start_time 必须是有效的非负数");
        }
        cmd.push_back("-ss");
        cmd.push_back(std::to_string(start_time));
    }

    // 硬件加速解码（纯音频模式跳过）
    if (!audio_only && HWACCEL_PARAMS.count(gpu)) {
        std::string encoder = resolveEncoder(gpu, video_codec);
        if (encoder != "copy") {
            for (auto& p : HWACCEL_PARAMS.at(gpu)) {
                cmd.push_back(p);
            }
        }
    }

    cmd.push_back("-i");
    cmd.push_back(input_path);

    // 封面图片作为第二个输入
    bool hasCoverInput = options.contains("cover_input") && options["cover_input"].is_string();
    if (hasCoverInput) {
        std::string cover = options["cover_input"].get<std::string>();
        if (!isPathSafe(cover))
            throw std::runtime_error("封面路径包含不安全字符");
        cmd.push_back("-i");
        cmd.push_back(cover);
    }

    // 片段截取结束时间（-ss 在 -i 前时用 -t duration，避免时间戳重置问题）
    if (options.contains("end_time") && !options["end_time"].is_null()) {
        double end_time;
        try {
            end_time = options["end_time"].get<double>();
        } catch (...) {
            throw std::runtime_error("end_time 必须是数字");
        }
        if (!std::isfinite(end_time) || end_time < 0) {
            throw std::runtime_error("end_time 必须是有效的非负数");
        }
        if (options.contains("start_time") && !options["start_time"].is_null()) {
            double start_time;
            try {
                start_time = options["start_time"].get<double>();
            } catch (...) {
                throw std::runtime_error("start_time 必须是数字");
            }
            double duration = end_time - start_time;
            if (duration > 0) {
                cmd.push_back("-t");
                cmd.push_back(std::to_string(duration));
            }
        } else {
            cmd.push_back("-to");
            cmd.push_back(std::to_string(end_time));
        }
    }

    // 纯音频模式：保留封面（attached_pic）和元数据
    bool removeCover = false;
    try {
        removeCover = options.value("remove_cover", false);
    } catch (...) {
        removeCover = false;
    }
    if (audio_only) {
        std::string out_ext;
        auto dot = output_path.rfind('.');
        if (dot != std::string::npos) out_ext = output_path.substr(dot + 1);
        // 用 unsigned char 转型，避免扩展名含非 ASCII 字节（负值）传给 tolower 触发 UB
        for (auto& c : out_ext) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));

        // 输入媒体类型：决定无封面时能否直接 -map 0（音频输入可安全保留 attached_pic；
        // 视频输入若 -map 0 会把视频流复制进 mp3/m4a，导致 muxer 报错或产生多余视频流）
        std::string input_media_type = "video";
        try {
            auto pr = probeVideo(input_path);
            if (pr.success) input_media_type = pr.info.value("media_type", "video");
        } catch (...) {}

        if (hasCoverInput) {
            // 嵌入新封面：映射音频流 + 新封面
            cmd.push_back("-map");
            cmd.push_back("0:a");
            cmd.push_back("-map");
            cmd.push_back("1:v");
            cmd.push_back("-c:v");
            cmd.push_back("copy");
            cmd.push_back("-disposition:v:0");
            cmd.push_back("attached_pic");
        } else if (removeCover || out_ext == "flac" || out_ext == "wav") {
            cmd.push_back("-vn");
        } else if (input_media_type == "audio") {
            // 音频输入：整段映射（含 attached_pic 封面）
            cmd.push_back("-map");
            cmd.push_back("0");
            cmd.push_back("-c:v");
            cmd.push_back("copy");
        } else {
            // 视频输入：只取音频流
            cmd.push_back("-map");
            cmd.push_back("0:a");
        }
        cmd.push_back("-map_metadata");
        cmd.push_back("0");

        // 嵌入歌词元数据
        if (options.contains("metadata") && options["metadata"].is_object()) {
            auto meta = options["metadata"];
            if (meta.contains("lyrics") && meta["lyrics"].is_string()) {
                std::string lyrics = meta["lyrics"].get<std::string>();
                // 歌词内容需要检查换行符（可能导致元数据注入）
                if (lyrics.find('\n') != std::string::npos || lyrics.find('\r') != std::string::npos) {
                    throw std::runtime_error("歌词内容包含非法字符");
                }
                cmd.push_back("-metadata");
                cmd.push_back("lyrics=" + lyrics);
            }
        }
        // 删除歌词
        bool remove_lyrics = false;
        try {
            remove_lyrics = options.value("remove_lyrics", false);
        } catch (...) {
            remove_lyrics = false;
        }
        if (remove_lyrics) {
            cmd.push_back("-metadata");
            cmd.push_back("lyrics=");
            cmd.push_back("-metadata");
            cmd.push_back("LYRICS=");
            cmd.push_back("-metadata");
            cmd.push_back("UNSYNCEDLYRICS=");
        }
    }

    // 编码参数
    auto enc_params = buildEncodingParams(options, input_pix_fmt);
    cmd.insert(cmd.end(), enc_params.begin(), enc_params.end());

    // 视频滤镜（如变速 setpts）— 纯音频模式跳过
    if (!audio_only && options.contains("vf_filters") && options["vf_filters"].is_array() && !options["vf_filters"].empty()) {
        std::string vf;
        for (auto& f : options["vf_filters"]) {
            if (!f.is_string()) {
                throw std::runtime_error("vf_filters 中的元素必须是字符串");
            }
            std::string fs = f.get<std::string>();
            if (!isFilterSafe(fs))
                throw std::runtime_error("视频滤镜包含不安全内容: " + fs);
            if (!vf.empty()) vf += ",";
            vf += fs;
        }
        cmd.push_back("-vf");
        cmd.push_back(vf);
    }

    // 音频滤镜（如变速 atempo）
    if (options.contains("af_filters") && options["af_filters"].is_array() && !options["af_filters"].empty()) {
        std::string af;
        for (auto& f : options["af_filters"]) {
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

    // 覆盖输出
    bool overwrite = true;
    try {
        overwrite = options.value("overwrite", true);
    } catch (...) {
        overwrite = true;
    }
    if (overwrite) {
        cmd.push_back("-y");
    }

    cmd.push_back(output_path);
    return cmd;
}

} // namespace ffmpegpp
