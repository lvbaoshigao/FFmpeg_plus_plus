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
        "libx264", "h264_amf", "h264_nvenc", "h264_qsv",
        "libx265", "hevc_amf", "hevc_nvenc", "hevc_qsv",
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
    std::string gpu = options.value("gpu", "CPU");
    std::string video_codec = options.value("video_codec", "h264");
    bool has_vf = options.contains("vf_filters") && options["vf_filters"].is_array() && !options["vf_filters"].empty();

    std::vector<std::string> params;

    // video_codec == "none" → 纯音频模式，禁用视频流
    if (video_codec == "none") {
        params.push_back("-vn");
    } else {
        if (has_vf && video_codec == "copy") {
            video_codec = "h264";
        }
        std::string encoder = resolveEncoder(gpu, video_codec);

        params.push_back("-c:v");
        params.push_back(encoder);

        if (options.contains("pix_fmt") && !options["pix_fmt"].is_null()) {
            std::string pf = options["pix_fmt"].get<std::string>();
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
            if (res.is_array() && res.size() == 2) {
                params.push_back("-s");
                params.push_back(std::to_string(res[0].get<int>()) + "x" + std::to_string(res[1].get<int>()));
            }
        }

        if (encoder != "copy") {
            if (options.contains("crf") && !options["crf"].is_null()) {
                params.push_back("-crf");
                params.push_back(std::to_string(options["crf"].get<int>()));
            } else if (options.contains("video_bitrate") && !options["video_bitrate"].is_null()) {
                params.push_back("-b:v");
                params.push_back(std::to_string(options["video_bitrate"].get<int>()) + "k");
            }

            if (options.contains("framerate") && !options["framerate"].is_null()) {
                params.push_back("-r");
                params.push_back(std::to_string(options["framerate"].get<double>()));
            }

            if (gpu == "CPU" && options.contains("preset")) {
                std::string pr = options["preset"].get<std::string>();
                if (!isInWhitelist(pr, VALID_PRESETS))
                    throw std::runtime_error("不支持的编码预设: " + pr);
                params.push_back("-preset");
                params.push_back(pr);
            }
        }
    }

    // 音频
    std::string audio_codec = options.value("audio_codec", "aac");
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
                params.push_back("-b:a");
                params.push_back(std::to_string(options["audio_bitrate"].get<int>()) + "k");
            }
            if (options.contains("sample_rate") && !options["sample_rate"].is_null()) {
                params.push_back("-ar");
                params.push_back(std::to_string(options["sample_rate"].get<int>()));
            }
        }
        if (options.contains("audio_channels") && !options["audio_channels"].is_null()) {
            params.push_back("-ac");
            params.push_back(std::to_string(options["audio_channels"].get<int>()));
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
    const json& options) {

    std::string gpu = options.value("gpu", "CPU");
    std::string video_codec = options.value("video_codec", "h264");
    bool audio_only = (video_codec == "none");

    // 探测源文件像素格式（纯音频模式跳过）
    std::string input_pix_fmt;
    if (!audio_only) {
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
        cmd.push_back("-ss");
        cmd.push_back(std::to_string(options["start_time"].get<double>()));
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

    // 片段截取结束时间
    if (options.contains("end_time") && !options["end_time"].is_null()) {
        cmd.push_back("-to");
        cmd.push_back(std::to_string(options["end_time"].get<double>()));
    }

    // 编码参数
    auto enc_params = buildEncodingParams(options, input_pix_fmt);
    cmd.insert(cmd.end(), enc_params.begin(), enc_params.end());

    // 视频滤镜（如变速 setpts）— 纯音频模式跳过
    if (!audio_only && options.contains("vf_filters") && options["vf_filters"].is_array() && !options["vf_filters"].empty()) {
        std::string vf;
        for (auto& f : options["vf_filters"]) {
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
    if (options.value("overwrite", true)) {
        cmd.push_back("-y");
    }

    cmd.push_back(output_path);
    return cmd;
}

} // namespace ffmpegpp
