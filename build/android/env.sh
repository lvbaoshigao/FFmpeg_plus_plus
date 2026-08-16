# FFmpeg++ Android 构建环境（缓存/工具链默认在 sdb2，可用环境变量覆盖）
#
# 目录约定：
#   FFMPEGPP_CACHE   —— 构建缓存根目录（默认: 本脚本所在盘的同级 android-build）
#   FFMPEGPP_ROOT    —— 仓库根目录（默认: 本脚本 ../../..）
# 工具链路径优先取环境变量，未设置时回落到 sdb2 已知位置，便于其它机器复用。

# 仓库根目录：build/android/env.sh → 上溯两级（build/android → build → 仓库根）
FFMPEGPP_ROOT="${FFMPEGPP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# 缓存根目录：默认与仓库同级（sdb2 下的 android-build）
FFMPEGPP_CACHE="${FFMPEGPP_CACHE:-$(dirname "$FFMPEGPP_ROOT")/android-build}"
mkdir -p "$FFMPEGPP_CACHE"

# 缓存盘根（sdb2 挂载点）= 缓存根上一级；normalize 掉 ../
_FFMPEGPP_DISK="$(cd "$FFMPEGPP_CACHE/.." && pwd)"

# ── 工具链（可覆盖） ──
export JAVA_HOME="${JAVA_HOME:-$_FFMPEGPP_DISK/apk_analysis/tools/jdk-21.0.2+13}"
export ANDROID_HOME="${ANDROID_HOME:-$_FFMPEGPP_DISK/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-$_FFMPEGPP_DISK/.android}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$_FFMPEGPP_DISK/gradle-home}"
# PUB_CACHE 必须显式覆盖：运行环境常预置 PUB_CACHE 指向嵌套的
# .../dart-pub-cache/cache（空缓存），而实际依赖在根目录 .../dart-pub-cache。
# 自定义路径请用 FFMPEGPP_PUB_CACHE。
export PUB_CACHE="${FFMPEGPP_PUB_CACHE:-$_FFMPEGPP_DISK/dart-pub-cache}"
export NDK_HOME="${NDK_HOME:-$_FFMPEGPP_DISK/reversing/tools/ndk/android-ndk-r26d}"
export FLUTTER_BIN="${FLUTTER_BIN:-/mnt/devtools/apps/flutter/bin}"

# ── PATH ──
export PATH="$FLUTTER_BIN:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

export FFMPEGPP_ROOT FFMPEGPP_CACHE
