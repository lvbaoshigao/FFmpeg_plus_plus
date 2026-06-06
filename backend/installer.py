"""
FFmpeg / FFprobe 检测与安装引导

只做检测 + 返回安装教程，不自动下载。

典型调用:
    from backend.installer import ensure_ffmpeg, find_ffmpeg

    result = find_ffmpeg()   # 返回 {found, path, version, ...}
    if not result["found"]:
        guide = get_install_guide()  # 返回 {url, steps, ...}
"""

import os
import shutil
import subprocess
from pathlib import Path
from collections import namedtuple

# ─────────────────────────────────────────────
# 返回结构
# ─────────────────────────────────────────────
EnvCheckResult = namedtuple("EnvCheckResult", [
    "found",       # bool
    "path",        # str | None   — ffmpeg/ffprobe 可执行文件完整路径
    "version",     # str | None   — 版本字符串（如 "ffmpeg version 7.0 ..."）
    "error",       # str | None   — 检测失败时的错误信息
])

InstallGuide = namedtuple("InstallGuide", [
    "platform",      # str  — "windows" / "macos" / "linux"
    "download_url",  # str  — 官方下载地址
    "steps",         # list[str] — 安装步骤
])


# ─────────────────────────────────────────────
# 查找可执行文件
# ─────────────────────────────────────────────

def _find_executable(name: str) -> str | None:
    """
    在 PATH 中查找可执行文件
    返回完整路径，未找到返回 None
    """
    # shutil.which 等价于 Unix which / Windows where
    # 在 Windows 上自动补全 .exe
    path = shutil.which(name)
    if path is not None:
        return path

    # 额外搜索常见安装路径 (Windows)
    if os.name == "nt":
        candidates = [
            Path("C:/ffmpeg/bin") / f"{name}.exe",
            Path("C:/Program Files/ffmpeg/bin") / f"{name}.exe",
            Path.home() / "ffmpeg/bin" / f"{name}.exe",
            Path.home() / "AppData/Local/ffmpeg/bin" / f"{name}.exe",
        ]
        for p in candidates:
            if p.exists():
                return str(p)

    return None


def _get_version(name: str) -> str | None:
    """
    运行 `{name} -version` 获取版本信息
    返回第一行版本字符串，失败返回 None
    """
    try:
        result = subprocess.run(
            [name, "-version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            timeout=10,
        )
        if result.returncode == 0:
            # 第一行通常是 "ffmpeg version 7.0-full_build-..." 类似格式
            return result.stdout.split("\n")[0].strip()
        return None
    except Exception:
        return None


# ─────────────────────────────────────────────
# 公共 API
# ─────────────────────────────────────────────

def find_ffmpeg() -> EnvCheckResult:
    """
    查找系统中的 ffmpeg
    """
    path = _find_executable("ffmpeg")
    if path is None:
        return EnvCheckResult(
            found=False,
            path=None,
            version=None,
            error="ffmpeg 未在 PATH 或常见安装目录中找到",
        )

    version = _get_version("ffmpeg")
    if version is None:
        return EnvCheckResult(
            found=False,
            path=path,
            version=None,
            error=f"在 {path} 找到 ffmpeg，但执行 -version 失败（可能损坏）",
        )

    return EnvCheckResult(found=True, path=path, version=version, error=None)


def find_ffprobe() -> EnvCheckResult:
    """
    查找系统中的 ffprobe
    """
    path = _find_executable("ffprobe")
    if path is None:
        return EnvCheckResult(
            found=False,
            path=None,
            version=None,
            error="ffprobe 未在 PATH 或常见安装目录中找到",
        )

    version = _get_version("ffprobe")
    if version is None:
        return EnvCheckResult(
            found=False,
            path=path,
            version=None,
            error=f"在 {path} 找到 ffprobe，但执行 -version 失败（可能损坏）",
        )

    return EnvCheckResult(found=True, path=path, version=version, error=None)


def ensure_ffmpeg() -> dict:
    """
    确保 ffmpeg 和 ffprobe 均已可用
    返回:
        {
            "ffmpeg":  EnvCheckResult,
            "ffprobe": EnvCheckResult,
            "all_ok":  bool,
        }
    """
    ffmpeg_result = find_ffmpeg()
    ffprobe_result = find_ffprobe()

    return {
        "ffmpeg": ffmpeg_result,
        "ffprobe": ffprobe_result,
        "all_ok": ffmpeg_result.found and ffprobe_result.found,
    }


def get_install_guide() -> InstallGuide:
    """
    根据当前操作系统返回安装指引
    只返回下载链接 + 文字步骤，不做任何自动安装动作
    """
    if os.name == "nt":
        return InstallGuide(
            platform="windows",
            download_url="https://ffmpeg.org/download.html#build-windows",
            steps=[
                "1. 打开 https://ffmpeg.org/download.html",
                "2. 在 'Windows Builds' 区域，选择 gyan.dev 或 BtbN 的预编译版本",
                "3. 推荐下载: 'ffmpeg-release-full.7z' (Full build, 包含所有编码器)",
                "4. 解压到固定目录，如 C:\\ffmpeg",
                "5. 将 C:\\ffmpeg\\bin 添加到系统 PATH 环境变量:",
                "   - Win+R → sysdm.cpl → 高级 → 环境变量",
                "   - 在「系统变量」中找到 Path → 编辑 → 新建 → C:\\ffmpeg\\bin",
                "6. 打开新的 cmd 窗口，输入 ffmpeg -version 验证",
            ],
        )

    if os.name == "posix":
        # 检查是 macOS 还是 Linux
        if "darwin" in os.uname().sysname.lower():
            return InstallGuide(
                platform="macos",
                download_url="https://ffmpeg.org/download.html#build-mac",
                steps=[
                    "推荐使用 Homebrew 安装:",
                    "  brew install ffmpeg",
                    "",
                    "或下载静态构建:",
                    "1. 打开 https://ffmpeg.org/download.html",
                    "2. 在 'macOS' 区域下载 static build",
                    "3. 解压后将 ffmpeg 和 ffprobe 放入 /usr/local/bin/",
                ],
            )
        else:
            return InstallGuide(
                platform="linux",
                download_url="https://ffmpeg.org/download.html#build-linux",
                steps=[
                    "Debian/Ubuntu:",
                    "  sudo apt update && sudo apt install ffmpeg",
                    "",
                    "RHEL/CentOS/Fedora:",
                    "  sudo dnf install ffmpeg   # 需先启用 RPM Fusion",
                    "",
                    "Arch Linux:",
                    "  sudo pacman -S ffmpeg",
                    "",
                    "或下载静态构建:",
                    "1. 打开 https://ffmpeg.org/download.html",
                    "2. 在 'Linux Static Builds' 区域下载",
                    "3. 解压后将 ffmpeg 和 ffprobe 放入 /usr/local/bin/",
                ],
            )

    # fallback
    return InstallGuide(
        platform="unknown",
        download_url="https://ffmpeg.org/download.html",
        steps=["请访问 https://ffmpeg.org/download.html 下载适合你系统的版本"],
    )


# ─────────────────────────────────────────────
# 便捷文本输出（给 UI 或 CLI 直接展示）
# ─────────────────────────────────────────────

def format_check_report(check_result: dict) -> str:
    """
    将 ensure_ffmpeg() 的结果格式化为可读文本
    用于直接显示给用户
    """
    lines = []
    ffmpeg = check_result["ffmpeg"]
    ffprobe = check_result["ffprobe"]

    lines.append("=" * 50)
    lines.append("FFmpeg Environment Check Report")
    lines.append("=" * 50)

    if ffmpeg.found:
        lines.append(f"[OK] ffmpeg  : {ffmpeg.path}")
        lines.append(f"             {ffmpeg.version}")
    else:
        lines.append(f"[MISS] ffmpeg  : not found — {ffmpeg.error}")

    if ffprobe.found:
        lines.append(f"[OK] ffprobe : {ffprobe.path}")
        lines.append(f"             {ffprobe.version}")
    else:
        lines.append(f"[MISS] ffprobe : not found — {ffprobe.error}")

    if not check_result["all_ok"]:
        guide = get_install_guide()
        lines.append("")
        lines.append(f"Download: {guide.download_url}")
        lines.append("Install steps:")
        for step in guide.steps:
            lines.append(f"   {step}")

    return "\n".join(lines)
