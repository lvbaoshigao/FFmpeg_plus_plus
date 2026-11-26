# 4.5 构建 Android APK

Android 的工作多一点，因为 APK 会一起打包 ffmpeg、ffprobe 和后端。先把原生部分准备好，再构建 Flutter / Gradle 应用。

## 先看宿主限制

当前 `build/android/build_ffmpeg.sh` 把 NDK 工具链路径写成 `prebuilt/linux-x86_64`，所以本页按 **Linux x86_64 主机**说明。不能把这套命令原样当作 macOS 或 Windows 原生构建教程。

当前 APK 只打包 **arm64-v8a**，最低 Android API 26（Android 8.0）。Gradle 的 NDK 打包配置为 `28.2.13676358`，与交叉编译 FFmpeg 所选 NDK 是两件事。

## 1. 准备并显式指定环境

安装 Flutter、JDK 17 或兼容环境、Android SDK、命令行工具，以及本页下方对应 NDK。先让 `flutter doctor -v` 确认 Android 工具链正常。

下面的 `/path/to/...` 是**需要替换的示意路径**。路径建议避免空格，因为当前原生构建脚本有未加引号的路径展开。

```sh
export JAVA_HOME="/path/to/jdk-17"
export ANDROID_HOME="/path/to/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export FLUTTER_BIN="/path/to/flutter/bin"
export FFMPEGPP_CACHE="/path/to/android-build-cache"
export GRADLE_USER_HOME="/path/to/gradle-cache"
export PUB_CACHE="/path/to/dart-pub-cache"
export NDK_HOME="$ANDROID_HOME/ndk/26.1.10909125"
export PATH="$FLUTTER_BIN:$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
```

将缓存目录放到空间充足、可写的位置。环境脚本会为未设置的变量回退到开发机路径，换机器时显式指定更容易排错。

### 为什么出现两个 NDK 版本？

当前 CI 实际安装 `26.1.10909125` 供原生脚本使用，同时安装 `28.2.13676358` 满足 Gradle 工程的打包配置。部分脚本注释仍提到 r26d，不应拿注释代替实际安装值。

```sh
sdkmanager --install "ndk;26.1.10909125" "ndk;28.2.13676358"
sdkmanager --licenses
```

还要安装当前 Flutter / Gradle 要求的 SDK 平台、build-tools 和 platform-tools，并保证 NDK sysroot 可写；原生脚本会在其中的 usr/local 安装依赖。工具版本以仓库实际配置为准。

## 2. 编译原生处理组件

回到仓库根目录运行：

```sh
bash build/android/build_ffmpeg.sh
```

脚本会下载并构建相关编解码依赖、FFmpeg / ffprobe 和后端，最终在 `$FFMPEGPP_CACHE/dist/` 提供：

- `libffmpegpp.so`：C++ 共享库。
- `libffmpeg.so`：供 Android 执行的 FFmpeg 文件。
- `libffprobe.so`：供 Android 执行的 ffprobe 文件。

后两个虽然以后缀 .so 打包，角色仍是可执行程序，不能拿桌面版 ELF 或普通共享库随意替换。

## 3. 构建 APK

```sh
bash build/android/build_apk.sh
```

脚本会从 dist 同步原生组件到 jniLibs、解析 pub 依赖、配置 SDK 路径、处理仓库内定义的插件补丁，再执行 Gradle Release 构建。

它会检查 FFmpeg 中是否包含 `h264_mediacodec` 标识。Android 当前已有 H.264 / HEVC MediaCodec 相关选项；实际能否使用取决于设备和编译能力，不能继续沿用“Android 一律不能硬编”的旧说法。

APK 目标路径：

```text
ffmpegpp_gui/build/app/outputs/flutter-apk/app-release.apk
```

## 4. 正式分发前检查签名

正式签名配置来自 `ffmpegpp_gui/android/key.properties`，格式可参考仓库的 example 文件。该文件和密钥库不要提交。

::: warning Release 构建不等于正式签名
没有 key.properties 时，当前工程会回退到 debug 签名，并打印警告。这样的产物可以用于本地验证，不能当作正式签名发布包。
:::

先在真实 arm64 Android 设备上安装并测试短素材，确认导入、探测、处理和输出访问均正常。构建完成本身不证明这些运行流程都已通过。

依据：[环境脚本](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/build/android/env.sh)、[APK 构建入口](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/build/android/build_apk.sh)、[Gradle 配置](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/android/app/build.gradle.kts)。
