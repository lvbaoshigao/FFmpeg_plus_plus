#pragma once
#include <string>
#include <vector>
#include <map>

namespace ffmpegpp {

// GPU 编码器映射
inline std::map<std::string, std::map<std::string, std::string>> GPU_ENCODERS = {
    {"CPU", {{"h264", "libx264"}, {"h265", "libx265"}, {"vp9", "libvpx-vp9"}}},
    {"NVIDIA", {{"h264", "h264_nvenc"}, {"h265", "hevc_nvenc"}, {"av1", "av1_nvenc"}}},
    {"AMD", {{"h264", "h264_amf"}, {"h265", "hevc_amf"}, {"av1", "av1_amf"}}},
    {"Intel", {{"h264", "h264_qsv"}, {"h265", "hevc_qsv"}, {"av1", "av1_qsv"}}},
};

// 硬件加速参数
inline std::map<std::string, std::vector<std::string>> HWACCEL_PARAMS = {
    {"NVIDIA", {}},
    {"Intel", {}},
    {"AMD", {}},
};

// 视频扩展名白名单
inline std::vector<std::string> VIDEO_EXTENSIONS = {
    "mp4", "avi", "mkv", "mov", "flv", "wmv",
    "webm", "m4v", "mpg", "mpeg", "3gp", "ts", "m2ts",
};

// 字幕扩展名白名单
inline std::vector<std::string> SUBTITLE_EXTENSIONS = {
    "srt", "ass", "ssa", "sub", "vtt", "idx", "sup",
};

// FFmpeg 参数说明
struct ParamInfo {
    std::string name;
    std::string category;
    std::string desc;
};

inline std::map<std::string, ParamInfo> FFMPEG_PARAMS_DESCRIPTION = {
    {"-i", {"输入文件", "输入/输出", "指定输入文件路径"}},
    {"-y", {"覆盖输出", "输入/输出", "不询问直接覆盖输出文件"}},
    {"-n", {"不覆盖", "输入/输出", "不覆盖已存在的文件"}},
    {"-f", {"封装格式", "输入/输出", "指定输出文件封装格式"}},
    {"-c:v", {"视频编码器", "视频", "指定视频编码器"}},
    {"-vcodec", {"视频编码器", "视频", "同 -c:v"}},
    {"-b:v", {"视频码率", "视频", "设置视频码率"}},
    {"-vf", {"视频滤镜", "视频", "应用视频滤镜链"}},
    {"-r", {"帧率", "视频", "设置视频帧率"}},
    {"-s", {"分辨率", "视频", "设置视频分辨率 (WxH)"}},
    {"-aspect", {"宽高比", "视频", "设置视频宽高比"}},
    {"-pix_fmt", {"像素格式", "视频", "设置像素格式"}},
    {"-crf", {"质量系数", "视频", "恒定质量 (0-51, 越小越清晰)"}},
    {"-preset", {"编码预设", "视频", "编码速度预设 (ultrafast ~ veryslow)"}},
    {"-profile:v", {"编码配置", "视频", "Profile (baseline/main/high)"}},
    {"-tune", {"调优", "视频", "编码器调优 (film/animation/grain…)"}},
    {"-g", {"关键帧间隔", "视频", "GOP 大小 / 关键帧间隔"}},
    {"-maxrate", {"最大码率", "视频", "最大码率限制"}},
    {"-bufsize", {"缓冲区大小", "视频", "码率控制缓冲区大小"}},
    {"-movflags", {"MOV 标志", "视频", "MP4/MOV 容器选项 (+faststart 等)"}},
    {"-c:a", {"音频编码器", "音频", "指定音频编码器"}},
    {"-acodec", {"音频编码器", "音频", "同 -c:a"}},
    {"-b:a", {"音频码率", "音频", "设置音频码率"}},
    {"-ar", {"采样率", "音频", "设置音频采样率"}},
    {"-ac", {"声道数", "音频", "设置音频声道数"}},
    {"-af", {"音频滤镜", "音频", "应用音频滤镜链"}},
    {"-c:s", {"字幕编码器", "字幕", "指定字幕编码器"}},
    {"-scodec", {"字幕编码器", "字幕", "同 -c:s"}},
    {"-hwaccel", {"硬件加速", "硬件加速", "启用硬件加速解码"}},
    {"-hwaccel_device", {"加速设备", "硬件加速", "指定硬件加速设备"}},
    {"-hwaccel_output_format", {"加速输出格式", "硬件加速", "指定硬件加速输出像素格式"}},
    {"-t", {"持续时间", "时间", "设置输出持续时间"}},
    {"-ss", {"开始时间", "时间", "设置开始时间点"}},
    {"-to", {"结束时间", "时间", "设置结束时间点"}},
    {"-map", {"流映射", "流控制", "手动映射输入流到输出"}},
    {"-vn", {"禁用视频", "流控制", "不复制视频流"}},
    {"-an", {"禁用音频", "流控制", "不复制音频流"}},
    {"-sn", {"禁用字幕", "流控制", "不复制字幕流"}},
    {"-dn", {"禁用数据", "流控制", "不复制数据流"}},
    {"-metadata", {"元数据", "其他", "设置文件元数据"}},
    {"-threads", {"线程数", "其他", "设置编码线程数"}},
};

// 默认字幕样式
struct SubtitleStyle {
    int font_size = 24;
    std::string font_name = "Arial";
    std::string font_color = "#FFFFFF";
    int outline_width = 2;
    std::string outline_color = "#000000";
};

} // namespace ffmpegpp
