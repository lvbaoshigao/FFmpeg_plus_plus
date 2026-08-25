#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# FFmpeg++ 一键编译三端
#   - build_all.sh desktop       仅桌面端（Linux/Windows，自动探测）
#   - build_all.sh android       仅 Android APK
#   - build_all.sh all           桌面端 + Android（默认）
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-all}"

case "$MODE" in
  desktop)
    "$SCRIPT_DIR/build_desktop.sh"
    ;;
  android)
    "$SCRIPT_DIR/android/build_apk.sh"
    ;;
  all)
    "$SCRIPT_DIR/build_desktop.sh"
    echo ""
    echo "══════════ 桌面端完成，开始构建 Android APK ══════════"
    echo ""
    "$SCRIPT_DIR/android/build_apk.sh"
    ;;
  *)
    echo "用法: $0 [all|desktop|android]"
    exit 1
    ;;
esac
