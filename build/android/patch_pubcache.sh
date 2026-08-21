#!/usr/bin/env bash
# 幂等修补 pub 缓存中 file_picker 的 compileSdk（34 → 36）。
# 原因：file_picker 8.x 的 android/build.gradle 固定 `compileSdk 34`，
# 而其依赖 flutter_plugin_android_lifecycle 2.0.35 要求 ≥36，
# 否则 Gradle 的 checkReleaseAarMetadata 失败。
# 修补目标在 PUB_CACHE（默认 sdb2 dart-pub-cache），重复执行安全。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

FP_DIR="$PUB_CACHE/hosted/pub.dev/file_picker-8.3.7/android"
FP_BUILD="$FP_DIR/build.gradle"

if [ ! -f "$FP_BUILD" ]; then
  # 尝试自动发现已缓存的 file_picker 版本
  FP_VERSION=$(ls "$PUB_CACHE/hosted/pub.dev/" 2>/dev/null | grep -E '^file_picker-' | sort -V | tail -1 || true)
  if [ -n "$FP_VERSION" ]; then
    FP_BUILD="$PUB_CACHE/hosted/pub.dev/$FP_VERSION/android/build.gradle"
  fi
fi

if [ ! -f "$FP_BUILD" ]; then
  echo "WARN: file_picker 未在 pub 缓存中找到，跳过 compileSdk 补丁" >&2
  exit 0
fi

if grep -q 'compileSdk 36' "$FP_BUILD"; then
  echo "pubcache: file_picker 已是 compileSdk 36，无需修补"
else
  sed -i 's/^    compileSdk 34$/    compileSdk 36/' "$FP_BUILD"
  echo "pubcache: 已修补 $FP_BUILD → compileSdk 36"
fi
