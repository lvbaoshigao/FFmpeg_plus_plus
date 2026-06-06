"""
常量定义模块
分辨率预设、编码器映射、FFmpeg 参数说明等
"""

# ============================================================
# 分辨率预设（从低到高排列，便于 UI 下拉框）
# ============================================================
RESOLUTION_PRESETS = {
    "2160p (4K)": (3840, 2160),
    "1440p (2K)": (2560, 1440),
    "1080p":     (1920, 1080),
    "720p":      (1280, 720),
    "480p":      (854, 480),
    "360p":      (640, 360),
    "自定义":    None,
}

# ============================================================
# GPU 硬件加速编码器映射
# key   = GPU 厂商名（与 UI 显示文本对应）
# value = {codec_key: ffmpeg_encoder_name}
# ============================================================
GPU_ENCODERS = {
    "CPU": {
        "h264": "libx264",
        "h265": "libx265",
        "vp9":  "libvpx-vp9",
    },
    "NVIDIA": {
        "h264": "h264_nvenc",
        "h265": "hevc_nvenc",
    },
    "AMD": {
        "h264": "h264_amf",
        "h265": "hevc_amf",
    },
    "Intel": {
        "h264": "h264_qsv",
        "h265": "hevc_qsv",
    },
}

# ============================================================
# 硬件加速解码参数
# 官方推荐同时指定 -hwaccel 和 -hwaccel_output_format
# dxva2 仅解码，输出仍在系统内存
# ============================================================
# NOTE: -hwaccel is intentionally empty.
# GPU decoding (hwaccel) puts frames in GPU memory, but CPU filters
# (scale, subtitles, etc.) require CPU memory → "Impossible to convert
# between the formats" error. Software decode + GPU encode is the safest
# cross-codec path and still provides 90%+ of the performance benefit.
HWACCEL_PARAMS = {
    "NVIDIA": [],
    "Intel":  [],
    "AMD":    [],
}

# ============================================================
# FFmpeg 参数说明字典
# 供 parser 模块使用
# ============================================================
FFMPEG_PARAMS_DESCRIPTION = {
    # ── 输入/输出 ──
    "-i":           {"name": "输入文件",   "category": "输入/输出", "desc": "指定输入文件路径"},
    "-y":           {"name": "覆盖输出",   "category": "输入/输出", "desc": "不询问直接覆盖输出文件"},
    "-n":           {"name": "不覆盖",     "category": "输入/输出", "desc": "不覆盖已存在的文件"},
    "-f":           {"name": "封装格式",   "category": "输入/输出", "desc": "指定输出文件封装格式"},

    # ── 视频编码 ──
    "-c:v":         {"name": "视频编码器", "category": "视频", "desc": "指定视频编码器"},
    "-vcodec":      {"name": "视频编码器", "category": "视频", "desc": "同 -c:v"},
    "-b:v":         {"name": "视频码率",   "category": "视频", "desc": "设置视频码率"},
    "-vf":          {"name": "视频滤镜",   "category": "视频", "desc": "应用视频滤镜链"},
    "-r":           {"name": "帧率",       "category": "视频", "desc": "设置视频帧率"},
    "-s":           {"name": "分辨率",     "category": "视频", "desc": "设置视频分辨率 (WxH)"},
    "-aspect":      {"name": "宽高比",     "category": "视频", "desc": "设置视频宽高比"},
    "-pix_fmt":     {"name": "像素格式",   "category": "视频", "desc": "设置像素格式"},
    "-crf":         {"name": "质量系数",   "category": "视频", "desc": "恒定质量 (0-51, 越小越清晰)"},
    "-preset":      {"name": "编码预设",   "category": "视频", "desc": "编码速度预设 (ultrafast ~ veryslow)"},
    "-profile:v":   {"name": "编码配置",   "category": "视频", "desc": "Profile (baseline/main/high)"},
    "-tune":        {"name": "调优",       "category": "视频", "desc": "编码器调优 (film/animation/grain…)"},
    "-g":           {"name": "关键帧间隔", "category": "视频", "desc": "GOP 大小 / 关键帧间隔"},
    "-maxrate":     {"name": "最大码率",   "category": "视频", "desc": "最大码率限制"},
    "-bufsize":     {"name": "缓冲区大小", "category": "视频", "desc": "码率控制缓冲区大小"},
    "-movflags":    {"name": "MOV 标志",   "category": "视频", "desc": "MP4/MOV 容器选项 (+faststart 等)"},

    # ── 音频编码 ──
    "-c:a":         {"name": "音频编码器", "category": "音频", "desc": "指定音频编码器"},
    "-acodec":      {"name": "音频编码器", "category": "音频", "desc": "同 -c:a"},
    "-b:a":         {"name": "音频码率",   "category": "音频", "desc": "设置音频码率"},
    "-ar":          {"name": "采样率",     "category": "音频", "desc": "设置音频采样率"},
    "-ac":          {"name": "声道数",     "category": "音频", "desc": "设置音频声道数"},
    "-af":          {"name": "音频滤镜",   "category": "音频", "desc": "应用音频滤镜链"},

    # ── 字幕 ──
    "-c:s":         {"name": "字幕编码器", "category": "字幕", "desc": "指定字幕编码器"},
    "-scodec":      {"name": "字幕编码器", "category": "字幕", "desc": "同 -c:s"},

    # ── 硬件加速 ──
    "-hwaccel":             {"name": "硬件加速",    "category": "硬件加速", "desc": "启用硬件加速解码"},
    "-hwaccel_device":      {"name": "加速设备",    "category": "硬件加速", "desc": "指定硬件加速设备"},
    "-hwaccel_output_format": {"name": "加速输出格式", "category": "硬件加速", "desc": "指定硬件加速输出像素格式"},

    # ── 时间控制 ──
    "-t":           {"name": "持续时间",   "category": "时间", "desc": "设置输出持续时间"},
    "-ss":          {"name": "开始时间",   "category": "时间", "desc": "设置开始时间点"},
    "-to":          {"name": "结束时间",   "category": "时间", "desc": "设置结束时间点"},

    # ── 流控制 ──
    "-map":         {"name": "流映射",     "category": "流控制", "desc": "手动映射输入流到输出"},
    "-vn":          {"name": "禁用视频",   "category": "流控制", "desc": "不复制视频流"},
    "-an":          {"name": "禁用音频",   "category": "流控制", "desc": "不复制音频流"},
    "-sn":          {"name": "禁用字幕",   "category": "流控制", "desc": "不复制字幕流"},
    "-dn":          {"name": "禁用数据",   "category": "流控制", "desc": "不复制数据流"},

    # ── 其他 ──
    "-metadata":    {"name": "元数据",     "category": "其他", "desc": "设置文件元数据"},
    "-threads":     {"name": "线程数",     "category": "其他", "desc": "设置编码线程数"},
}

# ============================================================
# 文件格式白名单
# ============================================================
VIDEO_EXTENSIONS = [
    "mp4", "avi", "mkv", "mov", "flv", "wmv",
    "webm", "m4v", "mpg", "mpeg", "3gp", "ts", "m2ts",
]

SUBTITLE_EXTENSIONS = [
    "srt", "ass", "ssa", "sub", "vtt", "idx", "sup",
]

# ============================================================
# 默认字幕样式
# ============================================================
DEFAULT_SUBTITLE_STYLE = {
    "font_size":      24,
    "font_name":      "Arial",
    "font_color":     "#FFFFFF",
    "outline_width":  2,
    "outline_color":  "#000000",
}
