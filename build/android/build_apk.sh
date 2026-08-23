#!/usr/bin/env bash
# 构建 APK（含重试）。系统内存紧张时 configure/编译阶段偶发 OOM SIGKILL；
# Gradle 缓存保证每次重试从上次进度继续，重试是安全的。
#
# 用法：
#   build/android/build_apk.sh              # 构建 release APK
#   环境变量：FFMPEGPP_CACHE / FFMPEGPP_ROOT 可覆盖默认缓存/仓库路径
#
# 依赖：jniLibs 里的 libffmpegpp.so（C++ 后端）+ assets 里的 ffmpeg/ffprobe
# （由 build/android/build_ffmpeg.sh 生成，产物在 $FFMPEGPP_CACHE/dist/）。
# 若仓库 jniLibs/assets 缺失，本脚本会尝试从缓存 dist/ 自动补齐。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# ── 1. 补齐 jniLibs + assets（幂等） ──
# libffmpegpp.so 是 C++ 后端动态库，放 jniLibs；
# ffmpeg/ffprobe 是静态可执行文件，放 assets（Android 安装器对 .so 做 ELF
# 校验，ET_EXEC 静态二进制可能不被解压到 nativeLibraryDir，导致 exec 报 127）。
JNI_DIR="$FFMPEGPP_ROOT/ffmpegpp_gui/android/app/src/main/jniLibs/arm64-v8a"
ASSET_DIR="$FFMPEGPP_ROOT/ffmpegpp_gui/android/app/src/main/assets"
mkdir -p "$JNI_DIR" "$ASSET_DIR"

# 动态库补齐
MISSING_JNI=""
for lib in libffmpegpp.so; do
  [ -f "$JNI_DIR/$lib" ] || MISSING_JNI="$MISSING_JNI $lib"
done
if [ -n "$MISSING_JNI" ]; then
  echo "jniLibs 缺少:$MISSING_JNI，尝试从缓存 dist/ 补齐..."
  for lib in $MISSING_JNI; do
    if [ -f "$FFMPEGPP_CACHE/dist/$lib" ]; then
      cp -f "$FFMPEGPP_CACHE/dist/$lib" "$JNI_DIR/$lib"
      echo "  已补齐 $lib"
    fi
  done
fi

# assets 补齐（dist/libffmpeg.so → assets/ffmpeg；dist/libffprobe.so → assets/ffprobe）
if [ ! -f "$ASSET_DIR/ffmpeg" ] && [ -f "$FFMPEGPP_CACHE/dist/libffmpeg.so" ]; then
  cp -f "$FFMPEGPP_CACHE/dist/libffmpeg.so" "$ASSET_DIR/ffmpeg"
  echo "  已补齐 assets/ffmpeg"
fi
if [ ! -f "$ASSET_DIR/ffprobe" ] && [ -f "$FFMPEGPP_CACHE/dist/libffprobe.so" ]; then
  cp -f "$FFMPEGPP_CACHE/dist/libffprobe.so" "$ASSET_DIR/ffprobe"
  echo "  已补齐 assets/ffprobe"
fi

# 终检
for lib in libffmpegpp.so; do
  if [ ! -f "$JNI_DIR/$lib" ]; then
    echo "ERROR: 缺少 $lib —— 请先运行 build/android/build_ffmpeg.sh 生成产物" >&2
    exit 1
  fi
done
for a in ffmpeg ffprobe; do
  if [ ! -f "$ASSET_DIR/$a" ]; then
    echo "ERROR: 缺少 assets/$a —— 请先运行 build/android/build_ffmpeg.sh 生成产物" >&2
    exit 1
  fi
done
echo "jniLibs + assets 已就绪"

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