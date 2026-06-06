"""
backend 公共工具模块
"""

from .constants import (
    GPU_ENCODERS,
    RESOLUTION_PRESETS,
    VIDEO_EXTENSIONS,
    SUBTITLE_EXTENSIONS,
    DEFAULT_SUBTITLE_STYLE,
    FFMPEG_PARAMS_DESCRIPTION,
)

from .exceptions import (
    FFmpegToolException,
    FFmpegNotFoundException,
    FFprobeNotFoundException,
    VideoParseException,
    SubtitleParseException,
    InvalidParameterException,
    FileCorruptedException,
    ProcessingException,
    CommandBuildException,
)

from .validators import (
    check_ffmpeg_installed,
    check_ffprobe_installed,
    validate_video_file,
    validate_subtitle_file,
    validate_resolution,
    validate_bitrate,
    validate_framerate,
    validate_output_path,
)
