"""
媒体文件信息探测模块

使用 ffprobe 获取视频/音频/字幕流详细信息。
所有函数返回结构化 dict，调用方可安全访问任意字段。

典型调用:
    from backend.probe import probe_video

    result = probe_video("C:/videos/demo.mp4")
    if result["success"]:
        print(result["info"]["resolution"])   # "1920x1080"
        for sub in result["info"]["subtitles"]:
            print(sub["language"])
"""

import json
import subprocess
from pathlib import Path
from collections import namedtuple

from .utils.validators import (
    check_ffprobe_installed,
    validate_video_file,
    validate_subtitle_file,
)
from .utils.exceptions import (
    VideoParseException,
    SubtitleParseException,
    FFprobeNotFoundException,
)

# ─────────────────────────────────────────────
# 返回结构
# ─────────────────────────────────────────────
ProbeResult = namedtuple("ProbeResult", [
    "success",      # bool
    "info",         # dict | None
    "error",        # str | None
    "raw_json",     # dict | None — ffprobe 原始 JSON
])


# ─────────────────────────────────────────────
# 底层: 调用 ffprobe
# ─────────────────────────────────────────────

def _run_ffprobe(filepath: str, timeout: int = 60) -> dict:
    """
    用 ffprobe 探测文件，返回原始 JSON dict

    Args:
        filepath: 媒体文件路径
        timeout: 超时秒数 (大文件可能较慢)

    Returns:
        ffprobe 的完整 JSON 输出（format + streams）

    Raises:
        FFprobeNotFoundException: ffprobe 不可用
        VideoParseException: ffprobe 执行失败或 JSON 无法解析
    """
    check_ffprobe_installed()

    cmd = [
        "ffprobe",
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        str(filepath),
    ]

    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise VideoParseException(f"ffprobe 执行超时 ({timeout}s): {filepath}")
    except Exception as e:
        raise VideoParseException(f"ffprobe 调用失败: {e}")

    if result.returncode != 0:
        raise VideoParseException(
            f"ffprobe 返回非零退出码 {result.returncode}: {result.stderr.strip()}"
        )

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise VideoParseException(f"ffprobe JSON 解析失败: {e}")


# ─────────────────────────────────────────────
# 内部辅助: 帧率计算
# ─────────────────────────────────────────────

def _parse_fps(stream: dict) -> float:
    """
    从流信息中解析帧率
    优先 r_frame_rate，回退 avg_frame_rate
    """
    for key in ("r_frame_rate", "avg_frame_rate"):
        if key in stream:
            fps_str = stream[key]
            if "/" in fps_str:
                num, den = fps_str.split("/")
                try:
                    den_int = int(den)
                    if den_int == 0:
                        continue  # 除零，跳过取下一候选
                    return round(int(num) / den_int, 2)
                except (ValueError, ZeroDivisionError):
                    continue
            try:
                return float(fps_str)
            except ValueError:
                continue
    return 0.0


def _detect_hdr(stream: dict) -> bool:
    """
    根据 color_transfer / color_space 检测是否为 HDR 内容
    """
    color_transfer = stream.get("color_transfer", "").lower()
    color_space = stream.get("color_space", "").lower()

    hdr_indicators = ["smpte2084", "arib-std-b67", "bt2020"]

    return any(
        indicator in color_transfer or indicator in color_space
        for indicator in hdr_indicators
    )


def _parse_subtitle_streams(streams: list) -> list[dict]:
    """
    解析字幕流列表
    """
    subtitles = []
    for i, stream in enumerate(streams):
        tags = stream.get("tags", {})
        disposition = stream.get("disposition", {})
        sub_info = {
            "index":    stream.get("index", i),
            "codec":    stream.get("codec_name", "N/A"),
            "language": tags.get("language", "N/A"),
            "title":    tags.get("title", "N/A"),
            "forced":   disposition.get("forced", 0) == 1,
            "default":  disposition.get("default", 0) == 1,
        }
        subtitles.append(sub_info)
    return subtitles


def _format_duration(seconds: float) -> str:
    """秒数 → HH:MM:SS 格式化"""
    if seconds <= 0:
        return "00:00:00"
    total = int(seconds)
    h = total // 3600
    m = (total % 3600) // 60
    s = total % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


# ─────────────────────────────────────────────
# 公共 API
# ─────────────────────────────────────────────

def probe_file(filepath: str) -> ProbeResult:
    """
    探测任意媒体文件的原始 ffprobe JSON

    Args:
        filepath: 文件路径

    Returns:
        ProbeResult(success, info=None, error, raw_json)
    """
    try:
        data = _run_ffprobe(filepath)
        return ProbeResult(success=True, info=None, error=None, raw_json=data)
    except FFprobeNotFoundException as e:
        return ProbeResult(success=False, info=None, error=str(e), raw_json=None)
    except VideoParseException as e:
        return ProbeResult(success=False, info=None, error=str(e), raw_json=None)
    except Exception as e:
        return ProbeResult(success=False, info=None, error=f"未知错误: {e}", raw_json=None)


def probe_video(filepath: str) -> ProbeResult:
    """
    解析视频文件信息

    返回 info 字段包含:
        - 基本信息: filename, filepath, format, size_mb, duration, duration_str,
                    bit_rate, bit_rate_kbps
        - 视频流:   codec, codec_long_name, profile, width, height, resolution,
                    aspect_ratio, pix_fmt, fps, frame_count, is_hdr,
                    color_space, color_transfer, color_primaries
        - 音频流:   audio_codec, audio_channels, audio_sample_rate, audio_bit_rate
        - 字幕流:   has_subtitles, subtitle_count, subtitles[{index, codec,
                    language, title, forced, default}]
    """
    # 1. 参数校验
    try:
        validate_video_file(filepath)
    except Exception as e:
        return ProbeResult(success=False, info=None, error=str(e), raw_json=None)

    # 2. ffprobe 探测
    try:
        data = _run_ffprobe(filepath)
    except (FFprobeNotFoundException, VideoParseException) as e:
        return ProbeResult(success=False, info=None, error=str(e), raw_json=None)

    # 3. 解析
    try:
        format_info = data.get("format", {})
        streams = data.get("streams", [])

        video_streams = [s for s in streams if s.get("codec_type") == "video"]
        audio_streams = [s for s in streams if s.get("codec_type") == "audio"]
        subtitle_streams = [s for s in streams if s.get("codec_type") == "subtitle"]

        if not video_streams:
            return ProbeResult(
                success=False,
                info=None,
                error="未检测到视频流",
                raw_json=data,
            )

        video = video_streams[0]
        audio = audio_streams[0] if audio_streams else {}
        format_size = int(format_info.get("size", 0))
        format_duration = float(format_info.get("duration", 0))

        info = {
            # ── 基本信息 ──
            "filename":         Path(filepath).name,
            "filepath":         str(filepath),
            "format":           format_info.get("format_name", "N/A"),
            "format_long_name": format_info.get("format_long_name", "N/A"),
            "size":             format_size,
            "size_mb":          round(format_size / (1024 * 1024), 2),
            "duration":         format_duration,
            "duration_str":     _format_duration(format_duration),
            "bit_rate":         int(format_info.get("bit_rate", 0)),
            "bit_rate_kbps":    round(int(format_info.get("bit_rate", 0)) / 1000, 2),

            # ── 视频流 ──
            "codec":            video.get("codec_name", "N/A"),
            "codec_long_name":  video.get("codec_long_name", "N/A"),
            "profile":          video.get("profile", "N/A"),
            "width":            video.get("width", 0),
            "height":           video.get("height", 0),
            "resolution":       f"{video.get('width', 0)}x{video.get('height', 0)}",
            "aspect_ratio":     video.get("display_aspect_ratio", "N/A"),
            "pix_fmt":          video.get("pix_fmt", "N/A"),
            "fps":              _parse_fps(video),
            "frame_count":      int(video["nb_frames"]) if "nb_frames" in video else "N/A",
            "is_hdr":           _detect_hdr(video),
            "color_space":      video.get("color_space", "N/A"),
            "color_transfer":   video.get("color_transfer", "N/A"),
            "color_primaries":  video.get("color_primaries", "N/A"),

            # ── 音频流 ──
            "audio_codec":       audio.get("codec_name", "N/A"),
            "audio_channels":    audio.get("channels", 0),
            "audio_sample_rate": audio.get("sample_rate", "N/A"),
            "audio_bit_rate":    int(audio.get("bit_rate", 0))
                                 if "bit_rate" in audio else 0,

            # ── 字幕流 ──
            "has_subtitles":   len(subtitle_streams) > 0,
            "subtitle_count":  len(subtitle_streams),
            "subtitles":       _parse_subtitle_streams(subtitle_streams),
        }

        return ProbeResult(success=True, info=info, error=None, raw_json=data)

    except Exception as e:
        return ProbeResult(
            success=False,
            info=None,
            error=f"解析视频信息时出错: {e}",
            raw_json=data,
        )


def probe_subtitle(filepath: str) -> ProbeResult:
    """
    解析字幕文件信息

    返回 info 字段包含:
        filename, filepath, format, size, size_kb,
        codec, codec_long_name, language, duration, duration_str
    """
    # 1. 参数校验
    try:
        validate_subtitle_file(filepath)
    except Exception as e:
        return ProbeResult(success=False, info=None, error=str(e), raw_json=None)

    # 2. ffprobe 探测
    try:
        data = _run_ffprobe(filepath)
    except (FFprobeNotFoundException, VideoParseException) as e:
        return ProbeResult(success=False, info=None, error=str(e), raw_json=None)

    # 3. 解析
    try:
        format_info = data.get("format", {})
        streams = data.get("streams", [])

        if not streams:
            return ProbeResult(
                success=False,
                info=None,
                error="未检测到字幕流",
                raw_json=data,
            )

        stream = streams[0]
        tags = stream.get("tags", {})
        format_size = int(format_info.get("size", 0))
        format_duration = float(format_info.get("duration", 0))

        info = {
            "filename":        Path(filepath).name,
            "filepath":        str(filepath),
            "format":          format_info.get("format_name", "N/A"),
            "size":            format_size,
            "size_kb":         round(format_size / 1024, 2),
            "codec":           stream.get("codec_name", "N/A"),
            "codec_long_name": stream.get("codec_long_name", "N/A"),
            "language":        tags.get("language", "N/A"),
            "duration":        format_duration,
            "duration_str":    _format_duration(format_duration),
        }

        return ProbeResult(success=True, info=info, error=None, raw_json=data)

    except Exception as e:
        return ProbeResult(
            success=False,
            info=None,
            error=f"解析字幕信息时出错: {e}",
            raw_json=data,
        )


# ─────────────────────────────────────────────
# FFmpeg 功能查询
# ─────────────────────────────────────────────

def _run(cmd: list[str], timeout: int = 15) -> str:
    """运行命令，返回 stdout"""
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           encoding="utf-8", errors="replace", timeout=timeout)
        return r.stdout
    except Exception:
        return ""


def query_ffmpeg_features() -> dict:
    """查询当前 FFmpeg 版本支持的所有功能"""
    features: dict[str, list[str]] = {}

    raw = _run(["ffmpeg", "-codecs", "-hide_banner"])
    for line in raw.splitlines():
        line = line.strip()
        if len(line) < 8 or line.startswith("-") or line.startswith("Codecs") or line.startswith("-------"):
            continue
        flags = line[:6]
        parts = line[6:].split(None, 2)
        if not parts:
            continue
        name = parts[0]
        desc = parts[2] if len(parts) > 2 else ""
        can_encode = "E" in flags[1:2]
        can_decode = "D" in flags[0:1]
        category = "other"
        if "V" in flags[2:3]:
            category = "video"
        elif "A" in flags[2:3]:
            category = "audio"
        elif "S" in flags[2:3]:
            category = "subtitle"
        entry = name
        if can_encode:
            entry += " [E]"
        if can_decode:
            entry += " [D]"
        if desc:
            entry += f" — {desc}"
        features.setdefault(f"codec_{category}", []).append(entry)

    raw = _run(["ffmpeg", "-formats", "-hide_banner"])
    for line in raw.splitlines():
        line = line.strip()
        if len(line) < 5 or line.startswith("--") or line.startswith("File") or line.startswith("D"):
            continue
        flags = line[:4]
        parts = line[4:].split(None, 1)
        if not parts:
            continue
        name = parts[0]
        desc = parts[1] if len(parts) > 1 else ""
        entry = name
        if desc:
            entry += f" — {desc}"
        features.setdefault("format", []).append(entry)

    raw = _run(["ffmpeg", "-filters", "-hide_banner"])
    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith(" ") and not line.startswith("T") and not line.startswith("..."):
            continue
        parts = line.split(None, 4)
        if len(parts) < 3:
            continue
        # line format: " T.. = name  description"
        name = parts[2] if len(parts) > 2 else parts[-1]
        desc = parts[4] if len(parts) > 4 else ""
        entry = name
        if desc:
            entry += f" — {desc}"
        features.setdefault("filter", []).append(entry)

    raw = _run(["ffmpeg", "-protocols", "-hide_banner"])
    in_output = False
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("Output:"):
            in_output = True
            continue
        if line.startswith("Input:"):
            in_output = True
            continue
        if not line or line.startswith("---"):
            continue
        if in_output and line and not line.startswith(" "):
            features.setdefault("protocol", []).append(line)
            in_output = False

    # 清理空分类
    features = {k: v for k, v in features.items() if v}
    return features
