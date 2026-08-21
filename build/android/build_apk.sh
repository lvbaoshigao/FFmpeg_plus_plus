#!/usr/bin/env bash
# 构建 APK（含重试）。系统内存紧张时 configure/编译阶段偶发 OOM SIGKILL；
# Gradle 缓存保证每次重试从上次进度继续，重试是安全的。
#
# 用法：
#   build/android/build_apk.sh              # 构建 release APK
#   环境变量：FFMPEGPP_CACHE / FFMPEGPP_ROOT 可覆盖默认缓存/仓库路径
#
# 依赖：jniLibs 里的 libffmpegpp.so / libffmpeg.so / libffprobe.so
# （由 build/android/build_ffmpeg.sh 生成，产物在 $FFMPEGPP_CACHE/dist/）。
# 若仓库 jniLibs 缺失，本脚本会尝试从缓存 dist/ 自动补齐。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# ── 1. 补齐 jniLibs（幂等） ──
JNI_DIR="$FFMPEGPP_ROOT/ffmpegpp_gui/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNI_DIR"
MISSING=""
for lib in libffmpegpp.so libffmpeg.so libffprobe.so; do
  [ -f "$JNI_DIR/$lib" ] || MISSING="$MISSING $lib"
done
if [ -n "$MISSING" ]; then
  echo "jniLibs 缺少:$MISSING，尝试从缓存 dist/ 补齐..."
  for lib in $MISSING; do
    if [ -f "$FFMPEGPP_CACHE/dist/$lib" ]; then
      cp -f "$FFMPEGPP_CACHE/dist/$lib" "$JNI_DIR/$lib"
      echo "  已补齐 $lib"
    fi
  done
  # 再次检查
  for lib in libffmpegpp.so libffmpeg.so libffprobe.so; do
    if [ ! -f "$JNI_DIR/$lib" ]; then
      echo "ERROR: 缺少 $lib —— 请先运行 build/android/build_ffmpeg.sh 生成产物" >&2
      exit 1
    fi
  done
else
  echo "jniLibs 已就绪"
fi

# ── 2. file_picker compileSdk 补丁（幂等） ──
# file_picker 8.x 固定 compileSdk 34，而其依赖 flutter_plugin_android_lifecycle
# 2.0.35 要求 ≥36；在 pub 缓存里打补丁，避免 AAR 元数据检查失败。
# 先确保 pub 缓存包含 file_picker（自愈，不依赖 workflow 时序）
if command -v flutter &>/dev/null; then
  (cd "$FFMPEGPP_ROOT/ffmpegpp_gui" && flutter pub get) || true
fi
bash "$SCRIPT_DIR/patch_pubcache.sh"

# ── 3. Gradle 构建（含 OOM 重试） ──
cd "$FFMPEGPP_ROOT/ffmpegpp_gui/android"
# 只编 arm64-v8a：Flutter Gradle 插件读取 project 属性 target-platform
# （默认 android-arm,android-arm64,android-x64）。限制后 jni 等插件的
# CMake 也不会为 4 个 ABI 重复编译，省一半磁盘和编译时间。
ARGS=(-Ptarget-platform=android-arm64)
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "======== ATTEMPT $i ========"
  if ./gradlew :app:assembleRelease --no-daemon "${ARGS[@]}" "$@"; then
    echo "BUILD SUCCESS on attempt $i"
    echo "APK: $FFMPEGPP_ROOT/ffmpegpp_gui/build/app/outputs/flutter-apk/app-release.apk"
    exit 0
  fi
  rc=$?
  echo "attempt $i failed (rc=$rc), sleeping 20s..."
  sleep 20
done
echo "ALL ATTEMPTS FAILED"
exit 1