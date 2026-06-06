"""
字幕烧录模块

支持外挂字幕文件（SRT/ASS/SSA 等）和内嵌字幕轨道选择。
路径自动做 ffmpeg 滤镜语法转义。

subtitle_options 结构:
{
    # ── 字幕来源（二选一）──
    "source": "external",             # "external" | "embedded"
    "subtitle_file": "C:/subs/01.ass", # 外挂字幕路径 (source=external)
    "subtitle_index": 0,               # 内嵌字幕轨道索引 (source=embedded)

    # ── 样式（仅 ASS/SSA 格式生效）──
    "style": {
        "font_size":      24,
        "font_name":      "Arial",
        "font_color":     "#FFFFFF",
        "outline_width":  2,
        "outline_color":  "#000000",
    },
}

video_options: 同 transcoder 模块的 options dict，为 None 时视频流直接 copy

典型调用:
    from backend.subtitle import burn_subtitles

    result = burn_subtitles(
        "input.mkv",
        "output.mkv",
        subtitle_options={
            "source": "external",
            "subtitle_file": "C:/subs/cn.ass",
            "style": {"font_size": 28, "font_color": "#FFFF00"},
        },
    )
"""

from pathlib import Path

from .utils.constants import DEFAULT_SUBTITLE_STYLE
from .utils.validators import validate_video_file, validate_subtitle_file, validate_output_path
from .utils.exceptions import CommandBuildException, InvalidParameterException
from .transcoder import _build_encoding_params
from .executor import run_ffmpeg, TaskResult


# ─────────────────────────────────────────────
# 路径安全转义（修复 P0: 补充单引号转义）
# ─────────────────────────────────────────────

def _escape_filter_path(filepath: str) -> str:
    """
    将 Windows 路径转换为 ffmpeg 滤镜语法安全的格式

    规则（经 ffmpeg 7.x/8.x 验证）:
        1. 反斜杠 → 正斜杠
        2. 盘符冒号 → \\:  转义
        3. 单引号   → '\\'' 转义（避免滤镜参数字符串提前闭合）

    示例:
        C:\\Users\\me\\That's It.srt
        → C\\:/Users/me/That'\\''s It.srt
    """
    p = str(Path(filepath).absolute())
    # 顺序重要：先转斜杠，再转义冒号，最后转义引号
    p = p.replace("\\", "/")
    p = p.replace(":", "\\:")
    p = p.replace("'", "'\\''")
    return p


# ─────────────────────────────────────────────
# 滤镜字符串构建
# ─────────────────────────────────────────────

def _build_subtitle_filter(
    input_path: str,
    subtitle_options: dict,
) -> str:
    """
    构建 ffmpeg subtitles 滤镜字符串

    Args:
        input_path: 输入视频路径（内嵌字幕时需要）
        subtitle_options: 字幕参数字典

    Returns:
        subtitles=... 滤镜字符串，可直接传给 -vf
    """
    source = subtitle_options.get("source", "external")

    if source == "external":
        subtitle_file = subtitle_options.get("subtitle_file")
        if not subtitle_file:
            raise CommandBuildException("外挂字幕模式需要提供 subtitle_file")

        validate_subtitle_file(subtitle_file)

        safe_path = _escape_filter_path(subtitle_file)
        filter_str = f"subtitles='{safe_path}'"

    elif source == "embedded":
        subtitle_index = subtitle_options.get("subtitle_index", 0)
        safe_input = _escape_filter_path(input_path)
        filter_str = f"subtitles='{safe_input}':si={subtitle_index}"

    else:
        raise CommandBuildException(f"未知字幕来源: {source}")

    # ── 样式附加（仅 ASS/SSA 有效，但语法上 SRT 不报错也不生效）──
    style = subtitle_options.get("style", {})
    if style:
        style_parts = []

        if "font_name" in style:
            style_parts.append(f"FontName={style['font_name']}")
        if "font_size" in style:
            style_parts.append(f"FontSize={style['font_size']}")
        if "font_color" in style:
            color = style["font_color"].lstrip("#")
            style_parts.append(f"PrimaryColour=&H{color}&")
        if "outline_width" in style:
            style_parts.append(f"Outline={style['outline_width']}")
        if "outline_color" in style:
            color = style["outline_color"].lstrip("#")
            style_parts.append(f"OutlineColour=&H{color}&")

        if style_parts:
            filter_str += f":force_style='{','.join(style_parts)}'"

    return filter_str


# ─────────────────────────────────────────────
# 命令构建
# ─────────────────────────────────────────────

def build_subtitle_command(
    input_path: str,
    output_path: str,
    subtitle_options: dict,
    video_options: dict | None = None,
) -> list[str]:
    """
    构建字幕烧录 ffmpeg 命令

    Args:
        input_path: 输入视频路径
        output_path: 输出视频路径
        subtitle_options: 字幕参数 dict
        video_options: 视频编码参数 dict（None = 视频流 copy）

    Returns:
        ffmpeg 命令 list
    """
    # ── 默认值 ──
    sub_opts = {
        "source": "external",
        "subtitle_index": 0,
        "style": dict(DEFAULT_SUBTITLE_STYLE),
        **subtitle_options,
    }

    # ── 校验 ──
    validate_video_file(input_path)
    validate_output_path(output_path)

    if sub_opts["source"] == "external":
        sub_file = sub_opts.get("subtitle_file")
        if not sub_file:
            raise CommandBuildException("字幕来源为 external 但未指定 subtitle_file")
        validate_subtitle_file(sub_file)

    # ── 组装命令 ──
    cmd = ["ffmpeg", "-i", str(input_path)]

    # 字幕滤镜
    subtitle_filter = _build_subtitle_filter(input_path, sub_opts)
    cmd.extend(["-vf", subtitle_filter])

    # 视频 + 音频编码（复用 transcoder 的公共 helper）
    if video_options is not None:
        cmd.extend(_build_encoding_params(video_options))
    else:
        # 不重新编码，视频/音频流直接复制
        cmd.extend(["-c:v", "copy", "-c:a", "copy"])

    cmd.append("-y")
    cmd.append(str(output_path))

    return cmd


# ─────────────────────────────────────────────
# 公共 API
# ─────────────────────────────────────────────

def burn_subtitles(
    input_path: str,
    output_path: str,
    subtitle_options: dict,
    *,
    video_options: dict | None = None,
    progress_callback=None,
    timeout: int = 3600,
) -> TaskResult:
    """
    字幕烧录

    Args:
        input_path: 输入视频路径
        output_path: 输出视频路径
        subtitle_options: 字幕参数 dict（见模块顶部结构说明）
        video_options: 视频编码参数 dict（None = 视频流直接 copy）
        progress_callback: 进度回调钩子（阶段2实现）
        timeout: 超时秒数

    Returns:
        TaskResult
    """
    try:
        cmd = build_subtitle_command(input_path, output_path, subtitle_options, video_options)
    except CommandBuildException as e:
        return TaskResult(False, None, str(e), [], [], 0.0, [])
    except InvalidParameterException as e:
        return TaskResult(False, None, str(e), [], [], 0.0, [])
    except Exception as e:
        return TaskResult(False, None, f"命令构建失败: {e}", [], [], 0.0, [])

    return run_ffmpeg(cmd, progress_callback=progress_callback, timeout=timeout)
