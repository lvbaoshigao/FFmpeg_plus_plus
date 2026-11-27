# 4.5 构建 Android APK

Android APK 会同时打包 ffmpeg、ffprobe 和后端。应先构建原生组件，再构建 Flutter / Gradle 应用。

## 主机环境限制

当前 `build/android/build_ffmpeg.sh` 将 NDK 工具链路径设为 `prebuilt/linux-x86_64`，因此该脚本适用于 **Linux x86_64 主机**。这些命令不能直接作为 macOS 或 Windows 原生构建步骤使用。

当前 APK 只打包 **arm64-v8a**，最低 Android API 26（Android 8.0）。Gradle 的 NDK 打包配置为 `28.2.13676358`，与交叉编译 FFmpeg 所选 NDK 是两件事。

## 1. 准备并显式指定环境

安装 Flutter、JDK 17 或兼容环境、Android SDK、命令行工具，以及下文对应版本的 NDK。通过 `flutter doctor -v` 确认 Android 工具链正常。

以下 `/path/to/...` 均为**需要替换的示意路径**。建议路径中不包含空格，因为当前原生构建脚本存在未加引号的路径展开。

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

请将缓存目录设置在空间充足且可写的位置。环境脚本会在变量未设置时回退到开发机路径；更换主机时显式设置这些变量有助于排查问题。

### NDK 版本配置说明

当前 CI 安装 `26.1.10909125` 供原生脚本使用，并安装 `28.2.13676358` 以满足 Gradle 工程的打包配置。部分脚本注释仍提到 r26d；实际安装版本应以配置和命令为准。

```sh
sdkmanager --install "ndk;26.1.10909125" "ndk;28.2.13676358"
sdkmanager --licenses
```

还需安装当前 Flutter / Gradle 所要求的 SDK 平台、build-tools 和 platform-tools，并确保 NDK sysroot 可写；原生脚本会在其 usr/local 目录中安装依赖。工具版本以仓库实际配置为准。

## 2. 编译原生处理组件

回到仓库根目录运行：

```sh
bash build/android/build_ffmpeg.sh
```

脚本会下载并构建相关编解码依赖、FFmpeg / ffprobe 和后端，最终在 `$FFMPEGPP_CACHE/dist/` 提供：

- `libffmpegpp.so`：C++ 共享库。
- `libffmpeg.so`：供 Android 执行的 FFmpeg 文件。
- `libffprobe.so`：供 Android 执行的 ffprobe 文件。

后两个文件虽以 .so 后缀打包，但其用途是可执行程序，不能用桌面版 ELF 文件或普通共享库替换。

## 3. 构建 APK

```sh
bash build/android/build_apk.sh
```

脚本会从 dist 同步原生组件到 jniLibs、解析 pub 依赖、配置 SDK 路径、处理仓库内定义的插件补丁，再执行 Gradle Release 构建。

该脚本会检查 FFmpeg 是否包含 `h264_mediacodec` 标识。Android 当前提供 H.264 / HEVC MediaCodec 相关选项，其实际可用性取决于设备与编译能力。

APK 目标路径：

```text
ffmpegpp_gui/build/app/outputs/flutter-apk/app-release.apk
```

## 4. 正式分发前的签名检查

正式签名配置来自 `ffmpegpp_gui/android/key.properties`，格式可参考仓库的 example 文件。请勿提交该文件或密钥库。

::: warning Release 构建不等于正式签名
未提供 key.properties 时，当前工程会回退到 debug 签名并输出警告。此类产物可用于本地验证，但不能作为正式签名的发布包。
:::

请先在真实 arm64 Android 设备上安装应用并测试短素材，确认导入、探测、处理和访问输出均正常。构建成功本身不能证明这些运行流程均已通过。

依据：[环境脚本](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/build/android/env.sh)、[APK 构建入口](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/build/android/build_apk.sh)、[Gradle 配置](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/android/app/build.gradle.kts)。
