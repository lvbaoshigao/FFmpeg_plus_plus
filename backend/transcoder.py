"""
视频转码 / 压缩模块

所有转码参数通过 options dict 传入，不拆分十几个独立参数。

options 结构:
{
    # ── 编码器 ──
    "video_codec":  "h264",           # h264 / h265 / vp9 / copy
    "gpu":          "CPU",            # CPU / NVIDIA / AMD / Intel
    "preset":       "medium",         # CPU 编码预设 (ultrafast ~ veryslow)

    # ── 视频参数 ──
    "resolution":   (1920, 1080),     # (width, height) 或 None = 保持
    "video_bitrate": 2000,            # kbps, None = 不设 (配合 crf)
    "framerate":    30,               # fps, None = 保持
    "crf":          None,             # CRF 质量模式 (0-51), None = 码率模式

    # ── 音频参数 ──
    "audio_codec":    "aac",          # 音频编码器, None = copy
    "audio_bitrate":  128,            # kbps
    "audio_channels": 2,              # 1 / 2 / 6, None = 保持

    # ── 其他 ──
    "extra_args": [],                 # 附加 ffmpeg 参数 (list)
    "overwrite":     True,            # 是否覆盖输出文件
}

典型调用:
    from backend.transcoder import transcode

    result = transcode(
        "input.mp4",
        "output.mp4",
        options={
            "video_codec": "h264",
            "gpu": "NVIDIA",
            "resolution": (1920, 1080),
            "video_bitrate": 3000,
            "audio_codec": "aac",
            "audio_bitrate": 128,
        },
    )
"""

from pathlib import Path

from .utils.constants import GPU_ENCODERS, HWACCEL_PARAMS
from .utils.validators import (
    validate_video_file,
    validate_resolution,
    validate_bitrate,
    validate_framerate,
    validate_output_path,
)
from .utils.exceptions import CommandBuildException, InvalidParameterException
from .executor import run_ffmpeg, TaskResult


# ─────────────────────────────────────────────
# 默认配置
# ─────────────────────────────────────────────
_DEFAULT_OPTIONS = {
    "video_codec":    "h264",
    "gpu":            "CPU",
    "preset":         "medium",
    "resolution":     None,
    "video_bitrate":  2000,
    "framerate":      None,
    "crf":            None,
    "audio_codec":    "aac",
    "audio_bitrate":  128,
    "audio_channels": 2,
    "extra_args":     [],
    "overwrite":      True,
}


# ─────────────────────────────────────────────
# 公共 helper（subtitle 模块也会调用）
# ─────────────────────────────────────────────

def _resolve_encoder(gpu: str, codec_key: str) -> str:
    """
    解析编码器名称。支持三种输入：
    1. 短键 (h264/h265/vp9) → 通过 GPU_ENCODERS 映射
    2. 完整编码器名 (libx264/h264_nvenc/mpeg4/...) → 直接使用
    3. "copy" → 流复制
    """
    if codec_key == "copy":
        return "copy"

    # 优先通过 GPU_ENCODERS 映射（短键）
    if gpu in GPU_ENCODERS and codec_key in GPU_ENCODERS[gpu]:
        return GPU_ENCODERS[gpu][codec_key]
    if codec_key in GPU_ENCODERS.get("CPU", {}):
        return GPU_ENCODERS["CPU"][codec_key]

    # 尝试作为原始编码器名直接使用
    # 常见编码器白名单（ffmpeg -encoders 输出的名称）
    _valid_encoders = {
        # H.264
        "libx264", "h264_amf", "h264_nvenc", "h264_qsv", "h264_vaapi",
        # H.265/HEVC
        "libx265", "hevc_amf", "hevc_nvenc", "hevc_qsv", "hevc_vaapi",
        # AV1
        "libaom-av1", "av1_amf", "av1_nvenc", "av1_qsv",
        # VP9
        "libvpx-vp9",
        # 其他
        "mpeg4", "prores_ks", "ffv1", "ffv1_vulkan",
        # 音频（不会被用到视频编码，但放这里安全）
        "aac", "libmp3lame", "libopus", "flac", "libfdk_aac",
    }
    if codec_key in _valid_encoders:
        return codec_key

    raise CommandBuildException(
        f"不支持的编码器: {codec_key}。支持的编码器: {sorted(_valid_encoders)}"
    )


def _build_encoding_params(options: dict) -> list[str]:
    """
    构建视频 + 音频编码参数（不含 -i / -y / 输出文件）
    返回纯参数 list，可嵌入任何 ffmpeg 命令中
    """
    opts = {**_DEFAULT_OPTIONS, **options}
    gpu = opts["gpu"]
    encoder = _resolve_encoder(gpu, opts["video_codec"])

    params = []

    # 视频编码器
    params.extend(["-c:v", encoder])

    # 分辨率
    if opts["resolution"] is not None:
        w, h = opts["resolution"]
        params.extend(["-s", f"{w}x{h}"])

    # 码率 / CRF
    if encoder != "copy":
        if opts["crf"] is not None:
            params.extend(["-crf", str(opts["crf"])])
        elif opts["video_bitrate"] is not None:
            params.extend(["-b:v", f"{opts['video_bitrate']}k"])

        # 帧率
        if opts["framerate"] is not None:
            params.extend(["-r", str(opts["framerate"])])

        # CPU 编码预设
        if gpu == "CPU" and opts["preset"]:
            params.extend(["-preset", opts["preset"]])

    # 音频
    if opts["audio_codec"] is not None:
        params.extend(["-c:a", opts["audio_codec"]])
        if opts["audio_bitrate"] is not None:
            params.extend(["-b:a", f"{opts['audio_bitrate']}k"])
        if opts["audio_channels"] is not None:
            params.extend(["-ac", str(opts["audio_channels"])])
    else:
        params.extend(["-c:a", "copy"])

    # 额外参数
    if opts.get("extra_args"):
        params.extend(opts["extra_args"])

    return params


# ─────────────────────────────────────────────
# 命令构建
# ─────────────────────────────────────────────

def build_transcode_command(
    input_path: str,
    output_path: str,
    options: dict,
) -> list[str]:
    """
    根据 options 构建 ffmpeg 命令列表
    """
    opts = {**_DEFAULT_OPTIONS, **options}

    # ── 参数校验 ──
    validate_video_file(input_path)
    validate_output_path(output_path)

    if opts["video_bitrate"] is not None:
        validate_bitrate(opts["video_bitrate"])
    if opts["framerate"] is not None:
        validate_framerate(opts["framerate"])
    if opts["resolution"] is not None:
        w, h = opts["resolution"]
        validate_resolution(w, h)

    gpu = opts["gpu"]
    encoder = _resolve_encoder(gpu, opts["video_codec"])

    # ── 组装命令 ──
    cmd = ["ffmpeg"]

    # 硬件加速解码
    if gpu in HWACCEL_PARAMS and encoder != "copy":
        cmd.extend(HWACCEL_PARAMS[gpu])

    cmd.extend(["-i", str(input_path)])

    # 视频 + 音频编码参数
    cmd.extend(_build_encoding_params(options))

    # 覆盖输出
    if opts["overwrite"]:
        cmd.append("-y")

    cmd.append(str(output_path))

    return cmd


# ─────────────────────────────────────────────
# 公共 API
# ─────────────────────────────────────────────

def transcode(
    input_path: str,
    output_path: str,
    options: dict | None = None,
    *,
    progress_callback=None,
    timeout: int = 3600,
) -> TaskResult:
    """
    视频转码 / 压缩

    Args:
        input_path: 输入视频路径
        output_path: 输出视频路径
        options: 转码参数 dict（见模块顶部结构说明）
        progress_callback: 进度回调 (stats: dict) -> None，阶段2实现
        timeout: 超时秒数（0 = 无限制）

    Returns:
        TaskResult(success, output_path, error, warnings, command, duration, log_lines)
    """
    if options is None:
        options = {}

    try:
        cmd = build_transcode_command(input_path, output_path, options)
    except CommandBuildException as e:
        return TaskResult(
            success=False,
            output_path=None,
            error=str(e),
            warnings=[],
            command=[],
            duration=0.0,
            log_lines=[],
        )
    except InvalidParameterException as e:
        return TaskResult(
            success=False,
            output_path=None,
            error=str(e),
            warnings=[],
            command=[],
            duration=0.0,
            log_lines=[],
        )
    except Exception as e:
        return TaskResult(
            success=False,
            output_path=None,
            error=f"命令构建失败: {e}",
            warnings=[],
            command=[],
            duration=0.0,
            log_lines=[],
        )

    return run_ffmpeg(cmd, progress_callback=progress_callback, timeout=timeout)
