#!/usr/bin/env bash
# 一键构建桌面端（Linux/Windows/macOS，按当前平台自动选择）。
#   1) 编译 C++ 后端 libffmpegpp.so / ffmpegpp.dll / libffmpegpp.dylib
#   2) flutter build <target> --release（强制 release，杜绝 debug 大包）
#   3) [macOS] 校验 release 产物特征（TRACK_WIDGET_CREATION 须为 false）
#   4) 把后端库拷贝进 Flutter bundle
# 用法：
#   build/build_desktop.sh [linux|windows|macos]
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

# macOS 强制校验：确实产出了 release 而非 debug。
# flutter 每次 build/run 都会重新生成 macos/Flutter/ephemeral/Flutter-Generated.xcconfig：
#   debug/profile  → TRACK_WIDGET_CREATION=true（引擎含调试代码，包体膨胀~10倍）
#   release        → TRACK_WIDGET_CREATION=false
# 若检测到 true（例如误用 flutter run / 配置被污染），直接报错拒绝交付。
if [ "$TARGET" = macos ]; then
  GEN_CFG="$ROOT/ffmpegpp_gui/macos/Flutter/ephemeral/Flutter-Generated.xcconfig"
  if [ -f "$GEN_CFG" ]; then
    if grep -q "^TRACK_WIDGET_CREATION=false" "$GEN_CFG"; then
      echo "✅ macOS release 特征确认: TRACK_WIDGET_CREATION=false"
    else
      echo "ERROR: macOS 产物为 debug/profile（TRACK_WIDGET_CREATION=true，" >&2
      echo "       '$GEN_CFG'）。" >&2
      echo "       请改用:  flutter build macos --release" >&2
      echo "       不要用 flutter run / flutter build macos（默认 debug），" >&2
      echo "       否则会产出膨胀约 10 倍、带调试引擎的 debug 包。" >&2
      exit 1
    fi
  else
    echo "WARN: 未找到 $GEN_CFG，跳过 release 特征校验（不影响产物）" >&2
  fi
fi

echo "==== [3/3] 拷贝后端库到 bundle ===="
case "$TARGET" in
  linux)
    DEST="$ROOT/ffmpegpp_gui/build/linux/x64/release/bundle/lib"
    ;;
  macos)
    # flutter build macos --release 的真实产物名为 ffmpegpp_gui.app
    # （PRODUCT_NAME=ffmpegpp_gui，见 AppInfo.xcconfig）。此前误写死成
    # "FFmpeg++.app/Contents/Frameworks" 会导致拷错位置、dylib 进不了包。
    RELEASE_DIR="$ROOT/ffmpegpp_gui/build/macos/Build/Products/Release"
    APP="$(find "$RELEASE_DIR" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -1)"
    [ -z "$APP" ] && { echo "ERROR: 未找到 macOS .app 产物（$RELEASE_DIR 下无 *.app），请确认 flutter build macos --release 已成功" >&2; exit 1; }
    # libffmpegpp.dylib 必须放 Contents/MacOS：main.dart 的 _findServer()
    # 从可执行文件（Contents/MacOS/ffmpegpp_gui）同级目录解析它。
    DEST="$APP/Contents/MacOS"
    ;;
  windows)
    DEST="$ROOT/ffmpegpp_gui/build/windows/x64/runner/Release"
    ;;
esac
mkdir -p "$DEST"
cp -f "$LIB" "$DEST/"
# 校验：后端库真实落进最终 bundle 目录
test -f "$DEST/$(basename "$LIB")" || { echo "ERROR: 后端库未成功拷入 bundle: $DEST/$(basename "$LIB")" >&2; exit 1; }
echo "已拷贝: $LIB → $DEST/"

# [macOS] 额外剥离调试符号（与 CI compile-macos 对齐，进一步减小包体）
if [ "$TARGET" = macos ]; then
  strip -S "$DEST/$(basename "$LIB")" 2>/dev/null || true
  find "$APP/Contents/Frameworks" -name '*.dylib' -exec strip -S {} \; 2>/dev/null || true
fi

echo "✅ 桌面端构建完成: $TARGET"
