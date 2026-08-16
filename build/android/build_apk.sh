#!/usr/bin/env bash
# 构建 APK（含重试）。系统内存紧张时 configure/编译阶段偶发 OOM SIGKILL；
# Gradle 缓存保证每次重试从上次进度继续，重试是安全的。
#
# 用法：
#   build/android/build_apk.sh              # 构建 release APK
#   环境变量：FFMPEGPP_CACHE / FFMPEGPP_ROOT 可覆盖默认缓存/仓库路径
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# file_picker 8.x 固定 compileSdk 34，而其依赖 flutter_plugin_android_lifecycle
# 2.0.35 要求 ≥36；在 pub 缓存里打补丁（幂等），避免 AAR 元数据检查失败。
"$SCRIPT_DIR/patch_pubcache.sh"

cd "$FFMPEGPP_ROOT/ffmpegpp_gui/android"
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "======== ATTEMPT $i ========"
  if ./gradlew :app:assembleRelease --no-daemon "$@"; then
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
