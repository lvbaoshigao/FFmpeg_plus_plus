# FFmpeg++ 统一构建目录（三端一键编译）

本目录集中管理 **Windows 桌面端 / Linux 桌面端 / Android 移动端** 的构建脚本，
遵循「代码在工作区、缓存/工具链在 sdb2」的约定，所有脚本均可通过环境变量覆盖路径。

## 目录结构

```
build/
├── build_all.sh            # 一键三端入口（all | desktop | android）
├── build_desktop.sh        # 桌面端一键构建（server_cpp + flutter build）
├── android/                # Android 端
│   ├── env.sh              # 公共环境：自动定位仓库根/缓存根 + 工具链
│   ├── build_ffmpeg.sh     # 交叉编译内置 ffmpeg/ffprobe + libffmpegpp.so（arm64）
│   ├── build_apk.sh        # 构建 APK（含 OOM 重试；自动打 file_picker 补丁）
│   └── patch_pubcache.sh   # 幂等修补 pub 缓存 file_picker compileSdk 34→36
```

## 快速开始

```bash
# 一键构建全部（桌面端 + Android APK）
build/build_all.sh all

# 只构建 Android APK
build/build_all.sh android

# 只构建桌面端（自动探测 Linux/Windows）
build/build_all.sh desktop

# Android 分步：先交叉编译 ffmpeg/后端（只需一次，产物在缓存根/dist/）
build/android/build_ffmpeg.sh
# 再构建 APK（自动补齐 jniLibs、自动打 file_picker 补丁、OOM 自动重试）
build/android/build_apk.sh
```

## 目录与路径约定（可覆盖）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `FFMPEGPP_ROOT` | 仓库根（脚本自动推导） | 代码所在位置 |
| `FFMPEGPP_CACHE` | 与仓库同级的 `android-build/` | 构建缓存根（sdb2） |
| `JAVA_HOME` | sdb2 `apk_analysis/tools/jdk-21.0.2+13` | JDK |
| `ANDROID_HOME` | sdb2 `android-sdk` | Android SDK |
| `GRADLE_USER_HOME` | sdb2 `gradle-home` | Gradle 缓存（转 SSD 时用符号链接保持路径） |
| `PUB_CACHE` | sdb2 `dart-pub-cache` | pub 依赖缓存 |
| `NDK_HOME` | sdb2 `reversing/tools/ndk/android-ndk-r26d` | NDK（r26d） |

> 注意：本机 sdb2 只有 20G，Gradle 的
> `caches/9.1.0/{transforms,generated-gradle-jars}` 已物理迁移到
> `/media/lvbaoshigao/SSD/ffmpegpp-build-cache/` 并以符号链接回填
> `GRADLE_USER_HOME/caches/9.1.0/` 下的原路径，脚本无需感知。

## 构建产物

| 平台 | 产物路径 |
|------|----------|
| Android APK | `ffmpegpp_gui/build/app/outputs/flutter-apk/app-release.apk`（arm64-v8a，内置 ffmpeg/ffprobe/后端） |
| Linux 桌面 | `ffmpegpp_gui/build/linux/x64/release/bundle/` |
| Windows 桌面 | `ffmpegpp_gui/build/windows/x64/runner/Release/` |

## 注意事项

- 系统内存紧张（7.7G），Android 构建偶发 OOM SIGKILL —— `build_apk.sh` 内置
  10 次重试循环，Gradle 缓存保证每次从上次进度继续，属正常现象。
- 不要修改 `org.gradle.configuration-cache` 相关属性（会导致构建失败）。
- 桌面端更新机制/安装器不适用于移动端；GPU 硬编码器在 Android 上不可用，
  自动回退 CPU 编码。
