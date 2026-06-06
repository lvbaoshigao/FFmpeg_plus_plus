"""
FFmpeg++ Backend — 纯 Python 后端模块

为上层（CLI / GUI / C++ 进程）提供稳定、结构化的 FFmpeg 操作接口。

模块一览:
    installer  — ffmpeg/ffprobe 检测 + 安装引导
    probe      — 媒体文件信息探测（视频/音频/字幕流）
    parser     — ffmpeg 命令字符串解析与解释
    transcoder — 视频转码 / 压缩（待实现）
    subtitle   — 字幕烧录（待实现）
    executor   — 统一任务执行 + 进度回调（待实现）

使用示例:
    from backend.installer import ensure_ffmpeg, get_install_guide
    from backend.probe import probe_video
    from backend.parser import explain_command
"""

__version__ = "0.1.0"

# ─────────────────────────────────────────────
# 统一返回结构（各模块共用）
# ─────────────────────────────────────────────
from collections import namedtuple

# 通用任务执行结果
TaskResult = namedtuple("TaskResult", [
    "success",      # bool       — 是否成功
    "output_path",  # str | None — 输出文件路径
    "error",        # str | None — 错误信息
    "warnings",     # list[str]  — 警告信息
    "command",      # list[str]  — 实际执行的 ffmpeg 命令
    "duration",     # float      — 执行耗时（秒）
    "log_lines",    # list[str]  — ffmpeg stderr 输出（截取最后 N 行）
])

# 环境检测结果
EnvCheckResult = namedtuple("EnvCheckResult", [
    "found",    # bool
    "path",     # str | None
    "version",  # str | None
    "error",    # str | None
])

# 安装指引
InstallGuide = namedtuple("InstallGuide", [
    "platform",      # str
    "download_url",  # str
    "steps",         # list[str]
])

# 媒体探测结果
ProbeResult = namedtuple("ProbeResult", [
    "success",   # bool
    "info",      # dict | None
    "error",     # str | None
    "raw_json",  # dict | None
])

# 命令解析结果
ParseResult = namedtuple("ParseResult", [
    "success",       # bool
    "explanations",  # list[dict]
    "categories",    # dict[str, list[dict]]
    "error",         # str | None
])
