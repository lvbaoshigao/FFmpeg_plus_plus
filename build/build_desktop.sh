#!/usr/bin/env bash
# 一键构建桌面端（Linux/Windows，按当前平台自动选择）。
#   1) 编译 C++ 后端 libffmpegpp.so / ffmpegpp.dll
#   2) flutter build linux/windows --release
#   3) 把后端库拷贝进 Flutter bundle
# 用法：
#   build/build_desktop.sh [linux|windows]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-}"

# 未指定平台时按当前系统推断
if [ -z "$TARGET" ]; then
  case "$(uname -s)" in
    Linux*)  TARGET=linux ;;
    MINGW*|MSYS*|CYGWIN*) TARGET=windows ;;
    Darwin*) TARGET=macos ;;
    *) echo "未知平台，请显式指定: build/build_desktop.sh [linux|windows|macos]"; exit 1 ;;
  esac
fi

echo "==== [1/3] 编译 C++ 后端 ($TARGET) ===="
case "$TARGET" in
  linux)
    cmake -S "$ROOT/server_cpp" -B "$ROOT/server_cpp/build_linux" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$ROOT/server_cpp/build_linux" -j"$(nproc)"
    LIB="$ROOT/server_cpp/build_linux/libffmpegpp.so"
    ;;
  macos)
    cmake -S "$ROOT/server_cpp" -B "$ROOT/server_cpp/build_macos" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$ROOT/server_cpp/build_macos" -j"$(nproc)"
    LIB="$ROOT/server_cpp/build_macos/libffmpegpp.dylib"
    ;;
  windows)
    cmake -S "$ROOT/server_cpp" -B "$ROOT/server_cpp/build_windows_x64" -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$ROOT/server_cpp/build_windows_x64"
    LIB="$ROOT/server_cpp/build_windows_x64/ffmpegpp.dll"
    ;;
  *) echo "不支持的平台: $TARGET"; exit 1 ;;
esac
test -f "$LIB" || { echo "后端库未生成: $LIB"; exit 1; }

echo "==== [2/3] flutter build $TARGET --release ===="
cd "$ROOT/ffmpegpp_gui"
flutter pub get
flutter build "$TARGET" --release

echo "==== [3/3] 拷贝后端库到 bundle ===="
case "$TARGET" in
  linux)  DEST="$ROOT/ffmpegpp_gui/build/linux/x64/release/bundle/lib" ;;
  macos)  DEST="$ROOT/ffmpegpp_gui/build/macos/Build/Products/Release/FFmpeg++.app/Contents/Frameworks" ;;
  windows) DEST="$ROOT/ffmpegpp_gui/build/windows/x64/runner/Release" ;;
esac
mkdir -p "$DEST"
cp -f "$LIB" "$DEST/"
echo "已拷贝: $LIB → $DEST/"
echo "✅ 桌面端构建完成: $TARGET"
