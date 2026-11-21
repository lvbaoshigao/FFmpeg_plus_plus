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

# 二次防护：jniLibs 的 ffmpeg 必须带 MediaCodec 硬编。dist 同步后立刻抽检，
# 若二进制里没有 h264_mediacodec，说明 dist/ 是旧缓存（或 git 还原的
# 旧二进制被同步进来了），硬失败而不是把无声退化的 APK 打出去。
# 用 `grep -aq` 直接搜二进制：本脚本开了 `set -o pipefail`，不要用
# `strings | grep -q`（grep -q 提前退出会让上游收到 SIGPIPE，匹配成功
# 也被判失败）。
if ! grep -aq 'h264_mediacodec' "$JNI_DIR/libffmpeg.so"; then
  echo "ERROR: jniLibs/libffmpeg.so 缺少 h264_mediacodec（移动端 GPU 编码会无声回退 CPU）" >&2
  echo "       请先运行 build/android/build_ffmpeg.sh 重建 dist 产物，再重试。" >&2
  exit 1
fi
echo "jniLibs 已就绪（dist → jniLibs 字节同步；PT_INTERP + mediacodec 验收通过）"

# Resolve exactly the checked-in package constraints. A failed pub get must
# stop here instead of allowing Gradle to consume a stale plugin configuration.
command -v flutter >/dev/null || { echo "ERROR: Flutter is not on PATH" >&2; exit 1; }
(cd "$FFMPEGPP_ROOT/ffmpegpp_gui" && flutter pub get)
FLUTTER_EXECUTABLE=$(readlink -f "$(command -v flutter)")
FLUTTER_SDK_DIR=$(cd "$(dirname "$FLUTTER_EXECUTABLE")/.." && pwd)
python3 "$SCRIPT_DIR/configure_local_properties.py" \
  --android-dir "$FFMPEGPP_ROOT/ffmpegpp_gui/android" \
  --flutter-sdk "$FLUTTER_SDK_DIR" \
  --android-sdk "$ANDROID_SDK_ROOT"
bash "$SCRIPT_DIR/patch_pubcache.sh"

# Share the repository policy with all Gradle builds, including Flutter SDK's
# included build. The application repositories alone cannot affect that build.
source "$SCRIPT_DIR/gradle_retry.sh"
cd "$FFMPEGPP_ROOT/ffmpegpp_gui/android"
chmod +x gradlew
ARGS=(-Ptarget-platform=android-arm64
      --init-script "$SCRIPT_DIR/gradle-repositories.init.gradle")
ffmpegpp_gradle_retry ./gradlew :app:assembleRelease --no-daemon "${ARGS[@]}" "$@"
echo "APK: $FFMPEGPP_ROOT/ffmpegpp_gui/build/app/outputs/flutter-apk/app-release.apk"
