# 4.1 构建前准备

本地构建前应区分两个任务：**编译应用**与**为应用准备 FFmpeg**。桌面 GUI 构建成功，并不表示运行环境中已具备 ffmpeg / ffprobe。

## 仓库各部分的职责

| 位置 | 作用 |
| --- | --- |
| `ffmpegpp_gui/` | Flutter 界面与各平台工程 |
| `server_cpp/` | C++17 原生后端，共享库目标为 ffmpegpp |
| `build/` | 项目自己的构建脚本，不是可以随意删掉的纯产物目录 |
| `.github/workflows/build-release.yml` | 现有发布流程，包含编译、打包和发布步骤 |
| `make/` | 图标、安装器与部分展示素材 |

后端经 FFI 与界面通信，再调用 FFmpeg / ffprobe 完成处理。Linux 的 Flutter CMake 工程会一起构建并打包后端；Windows 与 macOS 则需要把后端库放到最终应用查找的位置。

## 工具链要求

当前发布工作流固定使用 **Flutter 3.50.0**；GUI 的 pubspec 中 Dart 约束为 `^3.12.1`。建议本地首先使用与工作流相同的 Flutter 版本，再根据需要调整环境。

```sh
flutter --version
flutter doctor -v
cmake --version
```

C++ 后端要求 CMake 3.20+ 与 C++17 编译器。各平台还需要：

| 目标 | 主要环境 |
| --- | --- |
| Windows x64 | Windows、Visual Studio C++ 桌面开发组件与 Windows SDK；打安装包另需 Inno Setup |
| Linux x64 / ARM64 | 对应架构 Linux、GTK3、CMake、Ninja、编译器，以及 libsecret/GStreamer 等依赖 |
| macOS | macOS、Xcode 及其命令行工具，按 Flutter doctor 处理插件工具链要求 |
| Android arm64 | 本仓库原生脚本使用 Linux x86_64 主机、Android SDK、NDK、JDK 与 Flutter |

## 命令执行目录

除非另有说明，本章命令均从**仓库根目录**执行。运行 Flutter 命令前，先执行 `cd ffmpegpp_gui`。Android 路径通过环境变量设置，无需沿用开发者本机的绝对路径。

初次获取代码：

```sh
git clone https://github.com/lvbaoshigao/FFmpeg_plus_plus.git
cd FFmpeg_plus_plus
```

请确保依赖所需的 `third_party/` 内容完整。GUI 包含本地 path 依赖，因此仅复制 lib 目录不足以完成构建。

## 平台构建指南

- [Windows 构建](./windows.md)
- [Linux 构建](./linux.md)
- [macOS 构建](./macos.md)
- [Android 构建](./android.md)

仓库还提供 `build/build_all.sh desktop|android|all` 入口。其中 `all` 表示“当前宿主桌面端加 Android”，不表示在一台机器上交叉编译所有桌面平台；构建 Android 前仍须准备原生依赖。

::: info 构建步骤与验证范围
上述构建说明依据当前仓库脚本和发布工作流整理。帮助站构建成功不代表所有列出的目标平台均已验证构建通过。工具链发生变化时，应先检查命令输出中的首个实际错误，再参照[构建排障](./troubleshooting.md)。
:::
