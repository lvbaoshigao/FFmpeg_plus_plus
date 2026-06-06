"""
验证器模块
验证文件路径、编码参数等，不通过则抛出对应异常
"""

import os
import subprocess
from pathlib import Path

from .exceptions import *
from .constants import VIDEO_EXTENSIONS, SUBTITLE_EXTENSIONS


# ─────────────────────────────────────────────
# FFmpeg / FFprobe 存在性检查
# ─────────────────────────────────────────────

def check_ffmpeg_installed() -> bool:
    """
    检查 FFmpeg 是否可用（在 PATH 中且能正常执行 -version）
    成功返回 True，否则抛出 FFmpegNotFoundException
    """
    try:
        result = subprocess.run(
            ["ffmpeg", "-version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            timeout=10,
        )
        if result.returncode != 0:
            raise FFmpegNotFoundException(
                f"ffmpeg -version 返回非零退出码: {result.returncode}"
            )
        return True
    except FileNotFoundError:
        raise FFmpegNotFoundException()
    except subprocess.TimeoutExpired:
        raise FFmpegNotFoundException("ffmpeg -version 响应超时")
    except FFmpegToolException:
        raise
    except Exception as e:
        raise FFmpegNotFoundException(f"FFmpeg 检测失败: {e}")


def check_ffprobe_installed() -> bool:
    """
    检查 FFprobe 是否可用
    成功返回 True，否则抛出 FFprobeNotFoundException
    """
    try:
        result = subprocess.run(
            ["ffprobe", "-version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            timeout=10,
        )
        if result.returncode != 0:
            raise FFprobeNotFoundException(
                f"ffprobe -version 返回非零退出码: {result.returncode}"
            )
        return True
    except FileNotFoundError:
        raise FFprobeNotFoundException()
    except subprocess.TimeoutExpired:
        raise FFprobeNotFoundException("ffprobe -version 响应超时")
    except FFmpegToolException:
        raise
    except Exception as e:
        raise FFprobeNotFoundException(f"FFprobe 检测失败: {e}")


# ─────────────────────────────────────────────
# 文件校验
# ─────────────────────────────────────────────

def validate_video_file(filepath) -> bool:
    """
    验证视频文件
    - 路径非空
    - 文件存在且为普通文件
    - 扩展名在白名单中
    - 文件大小 > 0
    """
    if not filepath:
        raise InvalidParameterException("filepath", "文件路径为空")

    path = Path(filepath)

    if not path.exists():
        raise FileNotFoundError(f"文件不存在: {filepath}")

    if not path.is_file():
        raise InvalidParameterException("filepath", "不是有效的文件")

    ext = path.suffix.lower().lstrip(".")
    if ext not in VIDEO_EXTENSIONS:
        raise InvalidParameterException(
            "filepath",
            f"不支持的视频格式: .{ext}\n支持的格式: {', '.join(VIDEO_EXTENSIONS)}",
        )

    if path.stat().st_size == 0:
        raise FileCorruptedException(str(filepath), "文件大小为 0")

    return True


def validate_subtitle_file(filepath) -> bool:
    """
    验证字幕文件（可选：filepath 为 None / 空字符串时直接通过）
    """
    if not filepath:
        return True

    path = Path(filepath)

    if not path.exists():
        raise FileNotFoundError(f"字幕文件不存在: {filepath}")

    if not path.is_file():
        raise InvalidParameterException("subtitle", "不是有效的字幕文件")

    ext = path.suffix.lower().lstrip(".")
    if ext not in SUBTITLE_EXTENSIONS:
        raise InvalidParameterException(
            "subtitle",
            f"不支持的字幕格式: .{ext}\n支持的格式: {', '.join(SUBTITLE_EXTENSIONS)}",
        )

    return True


# ─────────────────────────────────────────────
# 参数范围校验
# ─────────────────────────────────────────────

def validate_resolution(width: int, height: int) -> bool:
    """分辨率校验（正整数，上限 8K）"""
    if not isinstance(width, int) or not isinstance(height, int):
        raise InvalidParameterException("resolution", "分辨率必须是整数")
    if width <= 0 or height <= 0:
        raise InvalidParameterException("resolution", "分辨率必须大于 0")
    if width > 7680 or height > 4320:
        raise InvalidParameterException("resolution", "分辨率超出支持范围（最大 8K）")
    return True


def validate_bitrate(bitrate) -> bool:
    """码率校验（>0，上限 100 Mbps）"""
    if not isinstance(bitrate, (int, float)):
        raise InvalidParameterException("bitrate", "码率必须是数字")
    if bitrate <= 0:
        raise InvalidParameterException("bitrate", "码率必须大于 0")
    if bitrate > 100000:
        raise InvalidParameterException("bitrate", "码率过高（最大 100 Mbps）")
    return True


def validate_framerate(fps) -> bool:
    """帧率校验（>0，上限 240 fps）"""
    if not isinstance(fps, (int, float)):
        raise InvalidParameterException("framerate", "帧率必须是数字")
    if fps <= 0:
        raise InvalidParameterException("framerate", "帧率必须大于 0")
    if fps > 240:
        raise InvalidParameterException("framerate", "帧率超出支持范围（最大 240 fps）")
    return True


def validate_output_path(path) -> bool:
    """
    验证输出路径：目录层级存在且可写，不存在则尝试创建
    """
    if not path:
        raise InvalidParameterException("output_path", "输出路径为空")

    output_dir = Path(path).parent

    if not output_dir.exists():
        try:
            output_dir.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            raise InvalidParameterException("output_path", f"无法创建输出目录: {e}")

    if not os.access(output_dir, os.W_OK):
        raise InvalidParameterException("output_path", "输出目录没有写入权限")

    return True
