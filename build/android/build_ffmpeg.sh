#!/usr/bin/env bash
# 为 Android (arm64-v8a) 交叉编译：
#   1) x264 / x265 / lame / opus / libwebp 静态库
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
JOBS="${JOBS:-2}"

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
    for url in "${urls[@]}"; do
      # 已有且校验通过的压缩包直接复用（配合 actions/cache 缓存 src/）
      if [ -f "$out" ] && is_valid_archive "$out"; then
        log "cached $out"
        return 0
      fi
      rm -f "$out"   # 残缺/无效文件先清掉，避免坏响应被误判为缓存
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

# ── 4.5 libwebp ──
# 图片转换为 webp 需要 libwebp 编码器；缺失时 ffmpeg 报
# "Error selecting an encoder / Encoder not found"。
# 关键：ffmpeg configure 对 libwebp 用 require_pkg_config（强制走 pkg-config），
# 不像 x264/x265 有裸库兜底探测。因此仅装 libwebp.a 不够，还必须保证
# $PREFIX/lib/pkgconfig/libwebp.pc 存在并可见（PKG_CONFIG_LIBDIR 指向该目录），
# 否则 configure 报 "libwebp >= 0.2.0 not found using pkg-config"。
# 缓存守卫：检查 .a、.pc 存在性，且 .pc 不得仍是 CMake 原版（带
# Requires.private，交叉编译下会让 pkg-config 失败）。任一不满足都强制重建，
# 使旧缓存（只有 .a、或 .pc 是坏版本）也能自愈。
if [ ! -f $PREFIX/lib/libwebp.a ] || [ ! -f $PREFIX/lib/pkgconfig/libwebp.pc ] || grep -q "Requires.private" "$PREFIX/lib/pkgconfig/libwebp.pc" 2>/dev/null; then
  fetch libwebp.tar.gz "https://github.com/webmproject/libwebp/archive/refs/tags/v1.4.0.tar.gz"
  rm -rf libwebp && mkdir libwebp && tar xf libwebp.tar.gz -C libwebp --strip-components=1
  log "building libwebp"
  cmake -S libwebp -B libwebp/build -G "Unix Makefiles" \
      -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
      -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-${API} \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DBUILD_SHARED_LIBS=OFF \
      -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
      -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
      -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
      > $BUILD/libwebp.log 2>&1
  cmake --build libwebp/build -j$JOBS >> $BUILD/libwebp.log 2>&1
  cmake --install libwebp/build >> $BUILD/libwebp.log 2>&1

  # 无条件覆盖 libwebp.pc：CMake 生成的版本带 `Requires.private: libsharpyuv`，
  # 即便 libsharpyuv.pc 也装了，交叉编译 + sysroot 重定位下 pkg-config 解析这
  # 条 Requires 链仍可能失败 → ffmpeg configure 报
  # "libwebp >= 0.2.0 not found using pkg-config"（require_pkg_config 强制走
  # pkg-config，无裸库兜底）。这里重写成无 Requires 依赖的版本，靠
  # Libs.private 显式带上 -lsharpyuv，兼顾静态链接需要 sharpyuv 符号。
  mkdir -p $PREFIX/lib/pkgconfig
  cat > $PREFIX/lib/pkgconfig/libwebp.pc <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libwebp
Description: Library for the WebP graphics format
Version: 1.4.0
Cflags: -I\${includedir}
Libs: -L\${libdir} -lwebp
Libs.private: -lsharpyuv -lm
EOF
  # 同步补一份 libsharpyuv.pc 简版（无依赖），防止旧缓存里残留的
  # libwebp.pc 若仍被读取仍引用 sharpyuv 时因缺 .pc 而失败。
  cat > $PREFIX/lib/pkgconfig/libsharpyuv.pc <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include/webp

Name: libsharpyuv
Description: Library for sharp RGB to YUV conversion
Version: 1.4.0
Cflags: -I\${includedir}
Libs: -L\${libdir} -lsharpyuv
Libs.private: -lm
EOF
  log "libwebp.pc / libsharpyuv.pc written (no Requires)"
else
  log "libwebp cached"
fi

# ── 5. ffmpeg ──
# 缓存守卫：sysroot 安装产物缺失，或已 stage 的 dist 二进制缺失/无效（缺 PT_INTERP）
# 都强制重建。教训：此前守卫只看 $PREFIX/bin/ffmpeg，ldflags 变更（-static-pie →
# 动态 PIE）后旧静态产物被原样 stage、打包、安装，app 内 exec 直接 SIGSEGV(-11)。
_ffmpeg_dist_ok() {
  [ -f $BUILD/dist/libffmpeg.so ] && [ -f $BUILD/dist/libffprobe.so ] || return 1
  for _b in $BUILD/dist/libffmpeg.so $BUILD/dist/libffprobe.so; do
    $TOOLCHAIN/bin/llvm-readelf -lW "$_b" 2>/dev/null \
        | grep -q 'Requesting program interpreter: /system/bin/linker64' || return 1
    # libc++_shared.so 是 NDK 私有库，设备不存在；configure 在检测到 C++ 依赖
    # 时会自动追加 -lc++，会拉入 NEEDED libc++_shared.so。缓存命中命中到旧
    # 产物时这里返回 1，强制走 then 分支重新构建。
    $TOOLCHAIN/bin/llvm-readelf -d "$_b" 2>/dev/null \
        | grep -q 'libc++_shared\.so' && return 1
    # 新增外部依赖（libwebp）后，旧的缓存产物不含该编码器，必须强制重建。
    # ffmpeg 二进制内嵌 encoder 名 "libwebp"，用 strings 探测即可判定。
    $TOOLCHAIN/bin/llvm-strings "$_b" 2>/dev/null | grep -q 'libwebp' || return 1
  done
  return 0
}
if [ ! -f $PREFIX/bin/ffmpeg ] || ! _ffmpeg_dist_ok; then
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
      --enable-libmp3lame --enable-libopus --enable-libwebp \
      --extra-cflags="-I$PREFIX/include $CFLAGS_COMMON" \
      --extra-ldflags="-L$PREFIX/lib -lm -Wl,--dynamic-linker=/system/bin/linker64 -Wl,--exclude-libs=ALL" \
      --extra-libs="-l:libc++.a -l:libunwind.a -ldl -lm" \
      > $BUILD/ffmpeg_config.log 2>&1 || { \
        echo "===== ffmpeg configure 失败诊断 ====="; \
        echo "--- config.log 中 libwebp / webp/encode / check_func_headers 相关 ---"; \
        grep -n -E "libwebp|webp/encode|WebPGetEncoder|check_func_headers|test_pkg_config|test_ld" $BUILD/ffmpeg_config.log | tail -40; \
        echo "--- config.log 末 60 行 ---"; \
        tail -60 $BUILD/ffmpeg_config.log; \
        echo "--- 真正的 ffbuild/config.log 中 libwebp / pkg-config 相关 ---"; \
        grep -n -E "libwebp|webp/encode|WebPGetEncoder|test_pkg_config|check_func_headers|test_ld|Package|not found|cannot find|error:" $BUILD/src/ffmpeg/ffbuild/config.log 2>&1 | tail -60; \
        echo "--- ffbuild/config.log 末 40 行 ---"; \
        tail -40 $BUILD/src/ffmpeg/ffbuild/config.log 2>&1; \
        echo "--- pkg-config 环境 ---"; \
        echo "PKG_CONFIG='$PKG_CONFIG'"; \
        echo "PKG_CONFIG_LIBDIR='$PKG_CONFIG_LIBDIR'"; \
        echo "PKG_CONFIG_SYSROOT_DIR='$PKG_CONFIG_SYSROOT_DIR'"; \
        echo "--- \$PREFIX/lib 实际内容 ---"; \
        ls -la $PREFIX/lib/ 2>&1 | head -40; \
        echo "--- \$PREFIX/include/webp 实际内容 ---"; \
        ls -la $PREFIX/include/webp/ 2>&1 | head -20; \
        echo "--- 全盘查找 libwebp/sharpyuv 产物（防装到意外位置）---"; \
        find $PREFIX -maxdepth 5 \( -name 'libwebp*' -o -name 'libsharpyuv*' -o -name 'encode.h' \) 2>/dev/null | head -40; \
        echo "--- 手动 pkg-config 检查 ---"; \
        $PKG_CONFIG --exists --print-errors "libwebp >= 0.2.0" 2>&1 && echo "[pkg-config exists] OK" || echo "[pkg-config exists] FAIL"; \
        echo "cflags: $($PKG_CONFIG --cflags --static libwebp 2>&1)"; \
        echo "libs:   $($PKG_CONFIG --libs --static libwebp 2>&1)"; \
        exit 1; }
  log "building ffmpeg"
  make -j$JOBS > $BUILD/ffmpeg_make.log 2>&1 || { tail -40 $BUILD/ffmpeg_make.log; exit 1; }
  make install >> $BUILD/ffmpeg_make.log 2>&1
  log "ffmpeg done"
else
  log "ffmpeg cached"
fi

# ── 6. 拷贝 ffmpeg/ffprobe 为 dist 产物。
#    动态 PIE（ET_DYN，带 PT_INTERP → /system/bin/linker64）二进制会被 Android
#    安装器解压到 nativeLibraryDir（可执行上下文），再由 build_apk.sh 转存到
#    jniLibs，Dart 侧直接 exec nativeLibraryDir/libffmpeg.so 与 libffprobe.so。──
cp -f $PREFIX/bin/ffmpeg  $BUILD/dist/libffmpeg.so
cp -f $PREFIX/bin/ffprobe $BUILD/dist/libffprobe.so

# ── 6.5 验收：stage 产物必须带 PT_INTERP（→ /system/bin/linker64）。
#     Android 只允许 exec 带 INTERP 的 ELF；缺 INTERP 的静态 PIE 一启动就
#     SIGSEGV(-11)。这里硬失败，杜绝坏产物流入 jniLibs / APK。──
for _b in $BUILD/dist/libffmpeg.so $BUILD/dist/libffprobe.so; do
  if ! $TOOLCHAIN/bin/llvm-readelf -lW "$_b" | grep -q 'Requesting program interpreter: /system/bin/linker64'; then
    echo "ERROR: $_b 缺少 PT_INTERP(/system/bin/linker64)，Android 上无法 exec" >&2
    echo "       请检查 configure 的 --extra-ldflags 是否保留了动态链接（勿加 -static/-static-pie）" >&2
    exit 1
  fi
  # 只允许依赖系统公共库（libc/libm/libdl）；libc++_shared.so 是 NDK 私有库，
  # 设备上不存在 —— 若 configure 自动附加了 -lc++（C 驱动检测到 libx265 C++
  # 依赖时会追加），在这里硬失败而不是装进 APK。
  #   extra-libs 已经用 -l:libc++.a -l:libunwind.a 显式链静态归档，
  #   --extra-ldflags 加 -Wl,--exclude-libs=ALL 防止外部 libc++.so 溜进 NEEDED；
  #   如果还是依赖 libc++_shared，说明你的 configure 检测逻辑有差异，请
  #   把 build_ffmpeg.sh 的 extra-libs 改为 ${NDK}/.../libc++_static.a 全路径。
  if $TOOLCHAIN/bin/llvm-readelf -d "$_b" | grep -q 'libc++_shared\.so'; then
    echo "ERROR: $_b 依赖 libc++_shared.so（系统不存在）" >&2
    echo "       1) 清掉 CI 缓存（dist 里的旧二进制）；" >&2
    echo "       2) 确认 NDK 的 sysroot 里有 sysroot/usr/lib/<triple>/<API>/libc++.a；" >&2
    echo "       3) 必要时改 --extra-libs 为绝对路径的 libc++_static.a。" >&2
    exit 1
  fi
done
log "ffmpeg/ffprobe staged (PT_INTERP ok): $(ls -la $BUILD/dist)"

# ── 7. libffmpegpp.so (C++ 后端) ──
# 用源码 hash 标记判断是否需要重建：即使 restore-keys 恢复了旧缓存，
# 只要 server_cpp 源码变了（hash 不匹配）就会强制重新编译，避免产物过时。
SRC_HASH=$(find "$FFMPEGPP_ROOT/server_cpp/src" "$FFMPEGPP_ROOT/server_cpp/include" \
    "$FFMPEGPP_ROOT/server_cpp/CMakeLists.txt" -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum | cut -d' ' -f1)
[ -z "$SRC_HASH" ] && SRC_HASH="nosrc"
CACHED_HASH=""
[ -f $BUILD/dist/libffmpegpp.so.hash ] && CACHED_HASH=$(cat $BUILD/dist/libffmpegpp.so.hash)
if [ -f $BUILD/dist/libffmpegpp.so ] && [ "$CACHED_HASH" = "$SRC_HASH" ]; then
  log "libffmpegpp.so cached (src hash match)"
else
  log "building libffmpegpp.so (src hash: $SRC_HASH)"
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
  echo "$SRC_HASH" > $BUILD/dist/libffmpegpp.so.hash
  log "libffmpegpp.so staged"
fi
ls -la $BUILD/dist
log "ALL DONE"
