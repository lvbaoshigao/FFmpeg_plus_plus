#!/usr/bin/env python
"""
FFmpeg++ JSON 协议服务器

通过 stdin/stdout 与前端（Flutter）通信。
每行一个完整 JSON 对象，以换行符分隔。

请求格式 (stdin):
    {"id": "req_001", "action": "probe", "params": {"filepath": "C:/video.mp4"}}
    {"id": "req_002", "action": "transcode", "params": {...}}
    {"id": "req_003", "action": "cancel"}

响应格式 (stdout):
    {"id": "req_001", "success": true, "data": {...}, "error": null}

进度推送 (stdout):
    {"type": "progress", "task_id": "req_002", "progress": 45.2, ...}
"""

import sys
import json
import time
import signal
import threading
import subprocess
import re
from pathlib import Path
from queue import Queue

# ── 确保 stdout 行缓冲（即使编译为 exe 也保证实时输出）──
sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
sys.stderr.reconfigure(encoding="utf-8", line_buffering=True)
try:
    sys.stdin.reconfigure(encoding="utf-8")
except Exception:
    pass
_stdout_lock = threading.Lock()  # 防止多线程 stdout 交错


# ═══════════════════════════════════════════════
# 进度解析器（从 ffmpeg stderr 提取进度）
# ═══════════════════════════════════════════════

class ProgressParser:
    """实时解析 ffmpeg stderr 输出"""

    def __init__(self, total_duration: float = 0.0):
        self.total_duration = total_duration
        self.current_time = 0.0
        self.speed = 0.0
        self.fps = 0.0
        self.bitrate = 0.0
        self.frame = 0

        self._time_re = re.compile(r"time=(\d{2}):(\d{2}):(\d{2}\.\d{2})")
        self._speed_re = re.compile(r"speed=\s*(\d+\.?\d*)x")
        self._fps_re = re.compile(r"fps=\s*(\d+\.?\d*)")
        self._bitrate_re = re.compile(r"bitrate=\s*(\d+\.?\d*)\s*kbits/s")
        self._frame_re = re.compile(r"frame=\s*(\d+)")

    def feed(self, line: str):
        m = self._time_re.search(line)
        if m:
            self.current_time = (
                int(m.group(1)) * 3600 +
                int(m.group(2)) * 60 +
                float(m.group(3))
            )
        m = self._speed_re.search(line)
        if m:
            self.speed = float(m.group(1))
        m = self._fps_re.search(line)
        if m:
            self.fps = float(m.group(1))
        m = self._bitrate_re.search(line)
        if m:
            self.bitrate = float(m.group(1))
        m = self._frame_re.search(line)
        if m:
            self.frame = int(m.group(1))

    @property
    def progress(self) -> float:
        if self.total_duration <= 0:
            return 0.0
        return min(self.current_time / self.total_duration * 100.0, 100.0)

    @property
    def remaining_seconds(self) -> float:
        if self.speed <= 0 or self.total_duration <= 0:
            return -1
        return (self.total_duration - self.current_time) / self.speed

    def stats(self) -> dict:
        remaining = self.remaining_seconds
        return {
            "progress": round(self.progress, 1),
            "current_time": _fmt_time(self.current_time),
            "total_time": _fmt_time(self.total_duration),
            "speed": f"{self.speed:.2f}x",
            "fps": f"{self.fps:.1f}",
            "bitrate": f"{self.bitrate:.1f} kb/s",
            "frame": self.frame,
            "remaining": _fmt_time(remaining) if remaining >= 0 else "N/A",
        }


def _fmt_time(seconds: float) -> str:
    if seconds < 0:
        seconds = 0
    total = int(seconds)
    h, m, s = total // 3600, (total % 3600) // 60, total % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


# ═══════════════════════════════════════════════
# 输出辅助
# ═══════════════════════════════════════════════

def _send(obj: dict):
    """线程安全地将 dict 序列化为一行 JSON 写入 stdout"""
    line = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    with _stdout_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def _reply(req_id: str, success: bool, data=None, error: str = None):
    _send({"id": req_id, "success": success, "data": data, "error": error})


def _progress(task_id: str, stats: dict):
    _send({"type": "progress", "task_id": task_id, **stats})


# ═══════════════════════════════════════════
# 命令冲突审计
# ═══════════════════════════════════════════

def _audit_command(cmd: list) -> list[str]:
    warnings = []
    has_hwaccel = any(a in cmd for a in ["-hwaccel"])
    has_hwaccel_fmt = any(a in cmd for a in ["-hwaccel_output_format"])
    has_scale = any(a in cmd for a in ["-s", "-vf", "-filter_complex"])
    has_nvenc = any("nvenc" in str(a) for a in cmd)

    if has_hwaccel and has_hwaccel_fmt and has_scale:
        warnings.append(
            "CONFLICT: -hwaccel + -hwaccel_output_format keeps frames in GPU memory, "
            "but -s/-vf filters require CPU memory. This will cause 'Impossible to convert' error."
        )
    if has_hwaccel and has_scale:
        warnings.append(
            "WARNING: -hwaccel with CPU scaling may cause format conversion errors."
        )

    input_files = [cmd[i+1] for i, a in enumerate(cmd) if a == "-i" and i+1 < len(cmd)]
    output_file = None
    for a in reversed(cmd):
        if not a.startswith("-") and a != "ffmpeg":
            output_file = a
            break
    if output_file and output_file in input_files:
        warnings.append("ERROR: Output file is the same as input file.")

    if has_nvenc and has_hwaccel_fmt:
        warnings.append("INFO: hwaccel_output_format may cause issues with nvenc.")

    return warnings


# ═══════════════════════════════════════════════
# 请求处理
# ═══════════════════════════════════════════════

def _handle_check_env(req: dict):
    try:
        from backend.installer import ensure_ffmpeg, get_install_guide
        env = ensure_ffmpeg()
        guide = get_install_guide() if not env["all_ok"] else None
        data = {
            "ffmpeg_found": env["ffmpeg"].found,
            "ffmpeg_path": env["ffmpeg"].path,
            "ffmpeg_version": env["ffmpeg"].version,
            "ffprobe_found": env["ffprobe"].found,
            "ffprobe_path": env["ffprobe"].path,
            "ffprobe_version": env["ffprobe"].version,
            "all_ok": env["all_ok"],
        }
        if guide:
            data["install_guide"] = {
                "platform": guide.platform,
                "download_url": guide.download_url,
                "steps": guide.steps,
            }
        _reply(req["id"], True, data)
    except Exception as e:
        _reply(req["id"], False, error=str(e))


def _handle_probe(req: dict):
    params = req.get("params", {})
    filepath = params.get("filepath", "")
    try:
        from backend.probe import probe_video
        result = probe_video(filepath)
        if result.success:
            _reply(req["id"], True, result.info)
        else:
            _reply(req["id"], False, error=result.error)
    except Exception as e:
        _reply(req["id"], False, error=str(e))


def _handle_query_features(req: dict):
    try:
        from backend.probe import query_ffmpeg_features
        features = query_ffmpeg_features()
        _reply(req["id"], True, features)
    except Exception as e:
        _reply(req["id"], False, error=str(e))


def _run_ffmpeg_process(task_id: str, cmd: list, cancel_event: threading.Event,
                        output_path: str):
    """执行 ffmpeg 子进程并实时推送进度"""
    total_duration = 0.0
    try:
        from backend.probe import probe_video
        for i, arg in enumerate(cmd):
            if arg == "-i" and i + 1 < len(cmd):
                probe_result = probe_video(cmd[i + 1])
                if probe_result.success and probe_result.info:
                    total_duration = probe_result.info.get("duration", 0.0)
                break
    except Exception:
        pass

    parser = ProgressParser(total_duration)
    start_time = time.time()
    stderr_lines = []
    process = None

    _progress(task_id, parser.stats())

    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )

        def read_stderr():
            try:
                for line in process.stderr:
                    stripped = line.rstrip()
                    if stripped:
                        stderr_lines.append(stripped)
                        parser.feed(stripped)
                        _progress(task_id, parser.stats())
            except Exception as e:
                _send({"type": "error", "error": f"stderr reader crashed: {e}"})

        reader = threading.Thread(target=read_stderr, daemon=True)
        reader.start()

        while process.poll() is None:
            if cancel_event.is_set():
                # Kill entire process tree on Windows
                try:
                    subprocess.run(['taskkill', '/F', '/T', '/PID', str(process.pid)],
                                   capture_output=True)
                except Exception:
                    process.kill()
                reader.join(timeout=1)
                _reply(task_id, False, error="任务已取消")
                return
            time.sleep(0.1)

        reader.join(timeout=2)
        returncode = process.returncode
        elapsed = time.time() - start_time

        if returncode == 0:
            _progress(task_id, {**parser.stats(), "progress": 100.0})
            out_size = 0
            if output_path and Path(output_path).exists():
                out_size = Path(output_path).stat().st_size
            _reply(task_id, True, data={
                "output_path": output_path,
                "output_size": out_size,
                "duration": round(elapsed, 2),
                "command": cmd,
            })
        else:
            error_msg = "; ".join(stderr_lines[-5:]) if stderr_lines else f"退出码 {returncode}"
            _reply(task_id, False, error=error_msg, data={
                "log_lines": stderr_lines[-100:],
                "command": cmd,
            })

    except FileNotFoundError:
        _reply(task_id, False, error="ffmpeg 可执行文件未找到")
    except Exception as e:
        _reply(task_id, False, error=str(e))
    finally:
        cancel_event.clear()


def _handle_transcode(req: dict, cancel_event: threading.Event):
    params = req.get("params", {})
    input_path = params.get("input", "")
    output_path = params.get("output", "")
    options = params.get("options", {})

    try:
        from backend.transcoder import build_transcode_command
        cmd = build_transcode_command(input_path, output_path, options)
    except Exception as e:
        _reply(req["id"], False, error=f"命令构建失败: {e}")
        return

    audit_warnings = _audit_command(cmd)
    if audit_warnings:
        _send({"type": "audit", "task_id": req["id"], "warnings": audit_warnings})

    _run_ffmpeg_process(req["id"], cmd, cancel_event, output_path)


def _handle_subtitle(req: dict, cancel_event: threading.Event):
    params = req.get("params", {})
    input_path = params.get("input", "")
    output_path = params.get("output", "")
    subtitle_options = params.get("subtitle_options", {})
    video_options = params.get("video_options")

    try:
        from backend.subtitle import build_subtitle_command
        cmd = build_subtitle_command(input_path, output_path, subtitle_options, video_options)
    except Exception as e:
        _reply(req["id"], False, error=f"命令构建失败: {e}")
        return

    audit_warnings = _audit_command(cmd)
    if audit_warnings:
        _send({"type": "audit", "task_id": req["id"], "warnings": audit_warnings})

    _run_ffmpeg_process(req["id"], cmd, cancel_event, output_path)


# ═══════════════════════════════════════════════
# 主入口: 后台线程读 stdin，主线程处理
# ═══════════════════════════════════════════════

def main():
    """JSON 协议主循环 — stdin 由后台线程读取，避免转码阻塞 cancel"""
    _send({"type": "ready", "version": "0.1.0"})
    # 诊断：输出实际编码信息到 stderr
    sys.stderr.write(f"[server] stdin encoding={sys.stdin.encoding}, stdout encoding={sys.stdout.encoding}\n")
    sys.stderr.flush()

    # 用于取消操作的跨线程事件
    cancel_event = threading.Event()
    # 请求队列：后台线程读取 stdin → 入队 → 主线程处理
    req_queue = Queue()
    shutdown_flag = threading.Event()

    def stdin_reader():
        """后台线程：持续读取 stdin。cancel/shutdown 直接处理，其余入队"""
        try:
            for line in sys.stdin:
                if shutdown_flag.is_set():
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    req = json.loads(line)
                except json.JSONDecodeError:
                    sys.stderr.write(f"[ERROR] 无效 JSON: {line[:300]}\n")
                    sys.stderr.flush()
                    _send({"type": "error", "error": f"无效的 JSON: {line[:100]}"})
                    continue
                action = req.get("action", "")
                # cancel 和 shutdown 必须立即处理，不能经过队列（主线程可能在转码中阻塞）
                if action == "cancel":
                    cancel_event.set()
                    _reply(req.get("id", ""), True, data={"message": "取消信号已发送"})
                elif action == "shutdown":
                    shutdown_flag.set()
                    cancel_event.set()
                    _reply(req.get("id", ""), True, data={"message": "服务器关闭"})
                    break
                elif action == "ping":
                    _reply(req.get("id", ""), True, data={"pong": True})
                else:
                    req_queue.put(req)
        except Exception:
            pass

    reader_thread = threading.Thread(target=stdin_reader, daemon=True)
    reader_thread.start()

    # 主线程：从队列中取请求并处理（可正确处理 cancel）
    while not shutdown_flag.is_set():
        try:
            req = req_queue.get(timeout=0.5)
        except Exception:
            # 超时后继续循环，检查 shutdown
            continue

        action = req.get("action", "")

        if action == "check_env":
            _handle_check_env(req)

        elif action == "probe":
            _handle_probe(req)

        elif action == "query_ffmpeg_features":
            _handle_query_features(req)

        elif action == "transcode":
            _handle_transcode(req, cancel_event)

        elif action == "subtitle":
            _handle_subtitle(req, cancel_event)

        else:
            _reply(req["id"], False, error=f"未知 action: {action}")

    # 清理
    cancel_event.set()
    reader_thread.join(timeout=2)


if __name__ == "__main__":
    main()
