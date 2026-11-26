# 4.1 构建前准备

想自己编译，先分清两件事：**编译应用**和**给应用安装 FFmpeg**。桌面 GUI 能编译出来，并不代表运行时已经有 ffmpeg / ffprobe。

## 仓库里各部分负责什么？

| 位置 | 作用 |
| --- | --- |
| `ffmpegpp_gui/` | Flutter 界面与各平台工程 |
| `server_cpp/` | C++17 原生后端，共享库目标为 ffmpegpp |
| `build/` | 项目自己的构建脚本，不是可以随意删掉的纯产物目录 |
| `.github/workflows/build-release.yml` | 现有发布流程，包含编译、打包和发布步骤 |
| `make/` | 图标、安装器与部分展示素材 |

后端经 FFI 与界面通信，再调用 FFmpeg / ffprobe 完成处理。Linux 的 Flutter CMake 工程会一起构建并打包后端；Windows 与 macOS 则需要把后端库放到最终应用查找的位置。

## 先核对工具链

当前发布工作流锁定 **Flutter 3.50.0**；Dart 约束在 GUI 的 pubspec 中为 `^3.12.1`。建议先与工作流使用同一 Flutter 版本，再做本地环境调整。

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

## 哪些命令在哪个目录运行？

本章除非特别注明，命令都从**仓库根目录**执行。`cd ffmpegpp_gui` 之后再运行 Flutter 命令。这里不会要求你照搬开发者本机磁盘路径；Android 的路径通过环境变量设置。

初次获取代码：

```sh
git clone https://github.com/lvbaoshigao/FFmpeg_plus_plus.git
cd FFmpeg_plus_plus
```

确保依赖所用的 `third_party/` 内容完整。GUI 中有本地 path 依赖，不要只复制 lib 目录来尝试构建。

## 选一条路线

- [Windows 构建](./windows.md)
- [Linux 构建](./linux.md)
- [macOS 构建](./macos.md)
- [Android 构建](./android.md)

仓库也有 `build/build_all.sh desktop|android|all` 入口。不过 `all` 的含义是“当前宿主桌面端加 Android”，不是在一台机器上跨编译所有桌面系统；Android 的原生依赖还要先准备。

::: info 这些步骤的核对范围
本章依据当前仓库脚本和发布工作流编写。帮助站构建成功，不代表这里列出的所有系统都在本次文档工作中重新编译过。遇到工具链变化，先看命令的第一处实际错误，再对照[构建排障](./troubleshooting.md)。
:::
