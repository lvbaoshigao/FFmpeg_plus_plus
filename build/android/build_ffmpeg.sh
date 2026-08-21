#!/usr/bin/env bash
# 为 Android (arm64-v8a) 交叉编译：
#   1) x264 / x265 / lame / opus 静态库
#   2) ffmpeg + ffprobe 静态可执行文件
#   3) libffmpegpp.so (C++ 后端)
# 所有中间产物与缓存放在缓存根目录（默认 sdb2 的 android-build）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

BUILD="${FFMPEGPP_CACHE}"
NDK="${NDK_HOME}"
TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64
SYSROOT=$TOOLCHAIN/sysroot
PREFIX=$SYSROOT/usr/local          # 装在 sysroot 内，pkg-config/链接路径天然正确
API=26
ARCH=aarch64
JOBS=2

mkdir -p $BUILD/src $BUILD/binwrap $BUILD/dist
cd $BUILD/src

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── 工具链包装 ──
# 注意：本机 NDK 的 aarch64-linux-android26-clang 包装脚本是"自执行"递归
# 死循环（被改动过）。必须直接用真实 clang/clang++ 二进制并显式
# --target=aarch64-linux-android<API>；*-gcc / *-g++ / *-cc 提供给
# x264/lame/opus 等 configure 使用。
log "preparing binwrap"
for t in ar ranlib nm strip as strings; do
  ln -sf $TOOLCHAIN/bin/llvm-$t $BUILD/binwrap/aarch64-linux-android-$t
done
cat > $BUILD/binwrap/aarch64-linux-android-gcc <<EOF
#!/bin/sh
exec $TOOLCHAIN/bin/clang --target=aarch64-linux-android${API} "\$@"
EOF
cat > $BUILD/binwrap/aarch64-linux-android-g++ <<EOF
#!/bin/sh
exec $TOOLCHAIN/bin/clang++ --target=aarch64-linux-android${API} "\$@"
EOF
cat > $BUILD/binwrap/aarch64-linux-android-cc <<EOF
#!/bin/sh
exec $TOOLCHAIN/bin/clang --target=aarch64-linux-android${API} "\$@"
EOF
chmod +x $BUILD/binwrap/aarch64-linux-android-gcc \
          $BUILD/binwrap/aarch64-linux-android-g++ \
          $BUILD/binwrap/aarch64-linux-android-cc
export PATH=$BUILD/binwrap:$PATH

CC=$BUILD/binwrap/aarch64-linux-android-gcc
CXX=$BUILD/binwrap/aarch64-linux-android-g++
CFLAGS_COMMON="--sysroot=$SYSROOT -O2 -fPIC"

# fetch <outfile> <url...> —— 下载源码包，校验 magic bytes 判定"真实压缩包"，
# 失败时清理残缺文件并依次尝试备用源。仅靠 curl -f 不够：
# 服务器有时会返回 HTTP 200 + HTML 错误页（前几 KB 是小 HTML），
# 此时 tar/bzip2 会直接报 "not a bzip2 file"。因此在解包前验证文件头。
fetch() {
  local out="$1"; shift
  local urls=("$@")
  for attempt in 1 2 3 4; do
    [ -f "$out" ] && rm -f "$out"   # 上一轮残缺文件（可能正是坏响应）先清掉
    for url in "${urls[@]}"; do
      log "downloading $out (attempt $attempt): $url"
      if curl -fSL --retry 3 --retry-delay 3 -o "$out" "$url" && is_valid_archive "$out"; then
        log "ok: $out ($(wc -c < "$out") bytes)"
        return 0
      fi
      rm -f "$out"
      log "download failed, trying next source..."
      sleep 3
    done
  done
  echo "DOWNLOAD FAILED: $out" >&2
  exit 1
}

# is_valid_archive <file> —— 按文件头判断是否为 gzip/bzip2/xz/tar 压缩包，
# 防止把服务器返回的 HTML 错误页当作源码包解压。
is_valid_archive() {
  local f="$1" magic
  [ -f "$f" ] || return 1
  magic="$(head -c 6 "$f" | od -An -tx1 | tr -d ' \n')"
  case "$magic" in
    1f8b*)    return 0 ;;  # gzip
    425a*)    return 0 ;;  # bzip2  (BZh)
    fd377a*)  return 0 ;;  # xz
    75657461*) return 0 ;; # tar (ustar)
    *)        return 1 ;;
  esac
}

# ── 1. x264 ──
if [ ! -f $PREFIX/lib/libx264.a ]; then
  fetch x264.tar.bz2 \
    "https://code.videolan.org/videolan/x264/-/archive/master/x264-master.tar.bz2" \
    "https://github.com/mirror/x264/archive/refs/heads/master.tar.gz"
  rm -rf x264 && mkdir x264 && tar xf x264.tar.bz2 -C x264 --strip-components=1
  cd x264
  log "building x264"
  ./configure --prefix=$PREFIX --host=aarch64-linux-android \
      --cross-prefix=aarch64-linux-android- --sysroot=$SYSROOT \
      --enable-static --disable-cli --disable-asm \
      --extra-cflags="$CFLAGS_COMMON" > $BUILD/x264.log 2>&1
  make -j$JOBS >> $BUILD/x264.log 2>&1
  make install >> $BUILD/x264.log 2>&1
  cd $BUILD/src
  log "x264 done"
else
  log "x264 cached"
fi

# ── 2. x265 ──
if [ ! -f $PREFIX/lib/libx265.a ]; then
  fetch x265.tar.gz "https://bitbucket.org/multicoreware/x265_git/downloads/x265_3.6.tar.gz"
  rm -rf x265 && mkdir x265 && tar xf x265.tar.gz -C x265 --strip-components=1
  log "building x265"
  cmake -S x265/source -B x265/build -G "Unix Makefiles" \
      -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
      -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-${API} \
      -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
      -DENABLE_ASSEMBLY=OFF \
      -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      > $BUILD/x265.log 2>&1
  cmake --build x265/build -j$JOBS >> $BUILD/x265.log 2>&1
  cmake --install x265/build >> $BUILD/x265.log 2>&1
  log "x265 done"
else
  log "x265 cached"
fi

# ── 3. lame ──
if [ ! -f $PREFIX/lib/libmp3lame.a ]; then
  fetch lame.tar.gz "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz"
  rm -rf lame && mkdir lame && tar xf lame.tar.gz -C lame --strip-components=1
  cd lame
  log "building lame"
  ./configure --host=aarch64-linux-android --prefix=$PREFIX \
      --disable-shared --enable-static --disable-frontend --disable-decoder \
      --disable-assembler --disable-rpath \
      CC=$CC "CFLAGS=$CFLAGS_COMMON" > $BUILD/lame.log 2>&1
  make -j$JOBS >> $BUILD/lame.log 2>&1
  make install >> $BUILD/lame.log 2>&1
  cd $BUILD/src
  log "lame done"
else
  log "lame cached"
fi

# ── 4. opus ──
if [ ! -f $PREFIX/lib/libopus.a ]; then
  fetch opus.tar.gz "https://github.com/xiph/opus/releases/download/v1.5.2/opus-1.5.2.tar.gz"
  rm -rf opus && mkdir opus && tar xf opus.tar.gz -C opus --strip-components=1
  cd opus
  log "building opus"
  ./configure --host=aarch64-linux-android --prefix=$PREFIX \
      --disable-shared --enable-static --disable-doc --disable-extra-programs \
      CC=$CC "CFLAGS=$CFLAGS_COMMON" > $BUILD/opus.log 2>&1
  make -j$JOBS >> $BUILD/opus.log 2>&1
  make install >> $BUILD/opus.log 2>&1
  cd $BUILD/src
  log "opus done"
else
  log "opus cached"
fi

# ── 5. ffmpeg ──
if [ ! -f $PREFIX/bin/ffmpeg ]; then
  fetch ffmpeg.tar.gz "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n8.0.tar.gz"
  rm -rf ffmpeg && mkdir ffmpeg && tar xf ffmpeg.tar.gz -C ffmpeg --strip-components=1
  cd ffmpeg
  log "configuring ffmpeg"
  # --host-cc 用系统 /usr/bin/gcc：PATH 里的 /mnt/devtools/usr/bin/gcc 缺少 cc1
  # pkg-config：libs 装在 sysroot 内，PCFILES 用 sysroot 前缀解析
  export PKG_CONFIG=/usr/bin/pkg-config
  export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
  export PKG_CONFIG_SYSROOT_DIR=$SYSROOT
  ./configure \
      --target-os=android --arch=aarch64 --cpu=armv8-a \
      --enable-cross-compile --cross-prefix=aarch64-linux-android- \
      --host-cc=/usr/bin/gcc \
      --pkg-config=/usr/bin/pkg-config \
      --cc=$CC --cxx=$CXX --sysroot=$SYSROOT \
      --ar=$TOOLCHAIN/bin/llvm-ar --nm=$TOOLCHAIN/bin/llvm-nm \
      --ranlib=$TOOLCHAIN/bin/llvm-ranlib --strip=$TOOLCHAIN/bin/llvm-strip \
      --prefix=$PREFIX \
      --enable-static --disable-shared --enable-pic \
      --disable-doc --disable-debug --disable-network --disable-ffplay \
      --enable-ffmpeg --enable-ffprobe --enable-small \
      --enable-gpl --enable-libx264 --enable-libx265 \
      --enable-libmp3lame --enable-libopus \
      --extra-cflags="-I$PREFIX/include $CFLAGS_COMMON" \
      --extra-ldflags="-static -L$PREFIX/lib -lm" \
      --extra-libs="-lc++ -l:libunwind.a -ldl -lm" \
      > $BUILD/ffmpeg_config.log 2>&1 || { tail -40 $BUILD/ffmpeg_config.log; exit 1; }
  log "building ffmpeg"
  make -j$JOBS > $BUILD/ffmpeg_make.log 2>&1 || { tail -40 $BUILD/ffmpeg_make.log; exit 1; }
  make install >> $BUILD/ffmpeg_make.log 2>&1
  log "ffmpeg done"
else
  log "ffmpeg cached"
fi

# ── 6. 拷贝 ffmpeg/ffprobe 为 libffmpeg.so / libffprobe.so（随 APK jniLibs 打包）──
cp -f $PREFIX/bin/ffmpeg  $BUILD/dist/libffmpeg.so
cp -f $PREFIX/bin/ffprobe $BUILD/dist/libffprobe.so
log "ffmpeg/ffprobe staged: $(ls -la $BUILD/dist)"

# ── 7. libffmpegpp.so (C++ 后端) ──
log "building libffmpegpp.so"
rm -rf $BUILD/server_cpp_build && mkdir -p $BUILD/server_cpp_build
cmake -S "$FFMPEGPP_ROOT/server_cpp" \
    -B $BUILD/server_cpp_build \
    -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-${API} \
    -DCMAKE_BUILD_TYPE=Release \
    > $BUILD/server_cpp_cmake.log 2>&1 || { tail -30 $BUILD/server_cpp_cmake.log; exit 1; }
cmake --build $BUILD/server_cpp_build -j$JOBS > $BUILD/server_cpp_make.log 2>&1 \
    || { tail -30 $BUILD/server_cpp_make.log; exit 1; }
cp -f $BUILD/server_cpp_build/libffmpegpp.so $BUILD/dist/libffmpegpp.so
log "libffmpegpp.so staged"
ls -la $BUILD/dist
log "ALL DONE"
