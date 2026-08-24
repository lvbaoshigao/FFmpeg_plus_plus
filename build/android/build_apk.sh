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

# 同步策略：以 dist/ 为准 —— jniLibs 是 git 追踪的（每个 build 都会 commit
# 一次二进制），但 ffmpeg 重新编译后 dist/ 是新鲜产物；这里强制 cp 覆盖，
# 防止 git checkout 还原的旧二进制被原样打包进 APK。
# 之前用 cmp -s 比对决定是否 cp，在某些 overlay/union 文件系统（GitHub
# Actions runner 偶发）会有 false negative，直接无条件 cp -f 更稳。
for lib in libffmpegpp.so libffmpeg.so libffprobe.so; do
  if [ ! -f "$FFMPEGPP_CACHE/dist/$lib" ]; then
    continue
  fi
  cp -f "$FFMPEGPP_CACHE/dist/$lib" "$JNI_DIR/$lib"
  echo "jniLibs/$lib 已从 dist/ 同步"
done

# 终检：dist/ 必须存在且三个二进制齐全。PT_INTERP 校验在 build_ffmpeg.sh 的
# stage 6.5 已经 hard-fail（确认 dist 阶段就拒绝无 INTERP 的产物），所以这里
# 不再重复检查 — 字节级 cp 后 jniLibs 与 dist 一定一致。
for lib in libffmpegpp.so libffmpeg.so libffprobe.so; do
  if [ ! -f "$JNI_DIR/$lib" ]; then
    echo "ERROR: 缺少 $lib —— 请先运行 build/android/build_ffmpeg.sh 生成产物" >&2
    exit 1
  fi
done
echo "jniLibs 已就绪（dist → jniLibs 字节同步；PT_INTERP 由 build_ffmpeg.sh 6.5 验收保证）"

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