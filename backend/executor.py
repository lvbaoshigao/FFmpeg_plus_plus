"""
单任务 FFmpeg 执行器（阶段1：同步执行 + 进度回调占位）

阶段2 时在此模块中补全完整的进度解析逻辑（正则匹配 stderr）。

典型调用:
    from backend.executor import run_ffmpeg

    result = run_ffmpeg(["ffmpeg", "-i", "in.mp4", "-c:v", "libx264", "out.mp4"])
    if result.success:
        print(f"完成，耗时 {result.duration:.1f}s")
    else:
        print(f"失败: {result.error}")
"""

import subprocess
import time
from pathlib import Path
from collections import namedtuple

from .installer import find_ffmpeg
from .utils.exceptions import FFmpegNotFoundException


# ─────────────────────────────────────────────
# 返回结构（与 backend/__init__.py 保持一致）
# ─────────────────────────────────────────────
TaskResult = namedtuple("TaskResult", [
    "success",      # bool
    "output_path",  # str | None
    "error",        # str | None
    "warnings",     # list[str]
    "command",      # list[str]
    "duration",     # float — 执行耗时（秒）
    "log_lines",    # list[str] — ffmpeg stderr 最后 N 行（最多保留 100 行）
])


# ─────────────────────────────────────────────
# 进度回调类型（文档用，阶段2实现具体逻辑）
# ─────────────────────────────────────────────
#
# def progress_callback(stats: dict) -> None:
#     """
#     阶段2 进度回调签名（占位）
#
#     stats 字段:
#         progress:      float   # 0.0 ~ 100.0
#         current_time:  str     # "00:05:23"
#         total_time:    str     # "00:10:00"
#         elapsed:       str     # "00:00:08"
#         remaining:     str     # "00:04:37"
#         speed:         str     # "1.50x"
#         fps:           str     # "30.5"
#         bitrate:       str     # "2500.3 kb/s"
#     """
#     pass


# ─────────────────────────────────────────────
# 执行器
# ─────────────────────────────────────────────

def run_ffmpeg(
    command: list[str],
    *,
    progress_callback=None,
    timeout: int = 0,
    log_limit: int = 100,
) -> TaskResult:
    """
    同步执行 ffmpeg 命令

    Args:
        command:          ffmpeg 参数列表（必须 list 传参，不能拼接字符串）
        progress_callback: 进度回调 (dict) -> None，阶段2实现具体解析
        timeout:          超时秒数，0 = 不限制
        log_limit:        错误时保留的最后 N 行 stderr

    Returns:
        TaskResult(success, output_path, error, warnings, command, duration, log_lines)
    """
    if not command:
        return TaskResult(False, None, "命令为空", [], [], 0.0, [])

    # ── 检查 ffmpeg 可用 ──
    try:
        check = find_ffmpeg()
        if not check.found:
            return TaskResult(
                False, None, f"ffmpeg 不可用: {check.error}", [], command, 0.0, []
            )
    except Exception as e:
        return TaskResult(
            False, None, f"ffmpeg 检测失败: {e}", [], command, 0.0, []
        )

    # ── 提取输出文件路径 ──
    output_path = _extract_output_path(command)

    # ── 执行 ──
    start_time = time.time()

    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            timeout=timeout if timeout > 0 else None,
        )
    except FileNotFoundError:
        # 防御：installer 说找到了但实际执行时找不到
        elapsed = time.time() - start_time
        return TaskResult(
            False, output_path,
            "ffmpeg 可执行文件未找到（可能刚刚被卸载或 PATH 变更）",
            [], command, elapsed, [],
        )
    except subprocess.TimeoutExpired:
        elapsed = time.time() - start_time
        return TaskResult(
            False, output_path,
            f"执行超时（{timeout}s）",
            [], command, elapsed, [],
        )
    except Exception as e:
        elapsed = time.time() - start_time
        return TaskResult(
            False, output_path,
            f"执行异常: {e}",
            [], command, elapsed, [],
        )

    elapsed = time.time() - start_time
    stderr_text = result.stderr or ""

    # ── 只保留最后 N 行 ──
    all_lines = stderr_text.splitlines()
    log_lines = all_lines[-log_limit:] if len(all_lines) > log_limit else all_lines

    # ── 收集警告（ffmpeg 的非致命输出通常不带 [error] 标记）──
    warnings = _extract_warnings(all_lines)

    # ── 阶段2 进度回调（当前为 noop）──
    if progress_callback is not None:
        # 阶段2: 这里接入 ProgressMonitor，逐行解析 stderr
        # 当前只通知完成
        try:
            progress_callback({
                "progress": 100.0 if result.returncode == 0 else 0.0,
                "current_time": "N/A",
                "total_time": "N/A",
                "elapsed": f"{elapsed:.1f}s",
                "remaining": "N/A",
                "speed": "N/A",
                "fps": "N/A",
                "bitrate": "N/A",
            })
        except Exception:
            pass  # 回调异常不应中断主流程

    # ── 判断结果 ──
    if result.returncode == 0:
        # 验证输出文件确实生成了
        if output_path and Path(output_path).exists() and Path(output_path).stat().st_size > 0:
            return TaskResult(True, output_path, None, warnings, command, elapsed, log_lines)
        elif output_path:
            return TaskResult(
                False, output_path,
                "ffmpeg 退出码为 0 但输出文件未生成或为空",
                warnings, command, elapsed, log_lines,
            )
        else:
            return TaskResult(True, None, None, warnings, command, elapsed, log_lines)

    # ── 失败 ──
    error_msg = _extract_error(all_lines) or f"ffmpeg 退出码 {result.returncode}"

    return TaskResult(False, output_path, error_msg, warnings, command, elapsed, log_lines)


# ─────────────────────────────────────────────
# 内部辅助
# ─────────────────────────────────────────────

def _extract_output_path(command: list[str]) -> str | None:
    """
    从 ffmpeg 命令中提取输出文件路径
    输出文件是 -y/-n 之后最后一个非参数 token
    """
    # 跳过 ffmpeg 本身
    tokens = command[1:] if command and command[0] == "ffmpeg" else command

    # 从后往前找第一个非选项 token
    for i in range(len(tokens) - 1, -1, -1):
        t = tokens[i]
        if not t.startswith("-") and t not in ("-y", "-n"):
            return t

    return None


def _extract_error(lines: list[str]) -> str | None:
    """
    从 stderr 行中提取错误信息
    查找包含 'error' / 'Error' / 'Invalid' / 'No such file' 的行
    """
    error_keywords = ["error", "Error", "Invalid", "No such file", "denied", "failed"]

    errors = []
    for line in lines:
        for kw in error_keywords:
            if kw.lower() in line.lower():
                errors.append(line.strip())
                break

    if errors:
        # 返回最后几条（最新的错误）
        return "; ".join(errors[-3:])

    # 回退：返回最后 3 行 stderr
    return "; ".join(line.strip() for line in lines[-3:] if line.strip()) or None


def _extract_warnings(lines: list[str]) -> list[str]:
    """提取警告信息"""
    warnings = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if "warning" in stripped.lower():
            warnings.append(stripped)
    return warnings
