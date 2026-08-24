#!/usr/bin/env bash
# 构建 APK（含重试）。系统内存紧张时 configure/编译阶段偶发 OOM SIGKILL；
# Gradle 缓存保证每次重试从上次进度继续，重试是安全的。
#
# 用法：
#   build/android/build_apk.sh              # 构建 release APK
#   环境变量：FFMPEGPP_CACHE / FFMPEGPP_ROOT 可覆盖默认缓存/仓库路径
#
# 依赖：jniLibs 里的 libffmpegpp.so、libffmpeg.so、libffprobe.so
# （由 build/android/build_ffmpeg.sh 生成，产物在 $FFMPEGPP_CACHE/dist/）。
# 每次构建前会以 dist/ 为准同步到 jniLibs（缺失或内容不一致均覆盖）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# ── 1. 补齐 jniLibs（幂等） ──
# libffmpegpp.so 是 C++ 后端动态库；libffmpeg.so / libffprobe.so 是动态 PIE
# 可执行文件（ET_DYN，带 PT_INTERP → /system/bin/linker64）。三者都放
# jniLibs/arm64-v8a：Android 安装器会解压到 nativeLibraryDir（可执行上下文），
# Dart 侧直接 exec nativeLibraryDir/libffmpeg.so 与 libffprobe.so。
JNI_DIR="$FFMPEGPP_ROOT/ffmpegpp_gui/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNI_DIR"

# 磁盘空间兜底：Gradle + AGP + 模块缓存加起来能轻松吃掉 4–6 GB；
# 如果 GRADLE_USER_HOME 所在盘剩余空间不足，提前报错并提示用户
# 把 GRADLE_USER_HOME 指向其它大点的盘（env.sh 的默认在 sdb2，可被环境变量覆盖）。
_GRADLE_DISK="$(df --output=avail -B1 "$GRADLE_USER_HOME" 2>/dev/null | tail -1 | tr -d ' \n' || true)"
if [ -n "$_GRADLE_DISK" ] && [ "$_GRADLE_DISK" -lt 5368709120 ]; then
  echo "WARN: GRADLE_USER_HOME=$GRADLE_USER_HOME 所在盘剩余 $(awk -v b="$_GRADLE_DISK" 'BEGIN{printf \"%.1f GB\", b/1024/1024/1024}')" >&2
  echo "      Gradle 首次构建可能需要 4–6 GB；建议提前设置 GRADLE_USER_HOME 指向其它盘：" >&2
  echo "        export GRADLE_USER_HOME=/media/lvbaoshigao/file/gradle-home" >&2
  echo "      当前继续尝试（重复构建时缓存已驻留，通常能完成）；如失败请按上式覆盖。" >&2
fi

# 同步策略：以 dist/ 为准 —— 缺失或与 dist 内容不一致的 .so 一律覆盖。
# 教训：此前"只补缺失"，dist 重新编译出动态 PIE 后，jniLibs 里残留的旧静态 PIE
# 二进制不会被替换，照样被打包进 APK，Android 14+ exec 仍然 SIGSEGV(-11)。
for lib in libffmpegpp.so libffmpeg.so libffprobe.so; do
  if [ ! -f "$FFMPEGPP_CACHE/dist/$lib" ]; then
    continue
  fi
  if [ ! -f "$JNI_DIR/$lib" ]; then
    cp -f "$FFMPEGPP_CACHE/dist/$lib" "$JNI_DIR/$lib"
    echo "jniLibs 缺少 $lib，已从 dist/ 补齐"
  elif ! cmp -s "$FFMPEGPP_CACHE/dist/$lib" "$JNI_DIR/$lib"; then
    cp -f "$FFMPEGPP_CACHE/dist/$lib" "$JNI_DIR/$lib"
    echo "jniLibs/$lib 与 dist/ 不一致，已用新产物覆盖"
  fi
done

# 终检
for lib in libffmpegpp.so libffmpeg.so libffprobe.so; do
  if [ ! -f "$JNI_DIR/$lib" ]; then
    echo "ERROR: 缺少 $lib —— 请先运行 build/android/build_ffmpeg.sh 生成产物" >&2
    exit 1
  fi
done
# PT_INTERP 验收：libffmpeg.so / libffprobe.so 必须能被 Android 直接 exec
# （带 INTERP → /system/bin/linker64）；否则装上设备后探测一律 SIGSEGV(-11)。
READELF="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
for lib in libffmpeg.so libffprobe.so; do
  if [ -x "$READELF" ] && ! "$READELF" -lW "$JNI_DIR/$lib" \
      | grep -q 'Requesting program interpreter: /system/bin/linker64'; then
    echo "ERROR: $JNI_DIR/$lib 缺少 PT_INTERP，无法在 Android 上 exec" >&2
    echo "       请重跑 build/android/build_ffmpeg.sh（勿用 -static/-static-pie 产物）" >&2
    exit 1
  fi
done
echo "jniLibs 已就绪（含 PT_INTERP 验收）"

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