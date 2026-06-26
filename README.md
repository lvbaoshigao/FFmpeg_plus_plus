# 🎬 FFmpeg++

<div align="center">

**专业视频处理桌面应用 — 100% AI 生成代码**

[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue?logo=windows)](https://www.microsoft.com/windows)
[![Flutter](https://img.shields.io/badge/Flutter-3.44+-02569B?logo=flutter)](https://flutter.dev)
[![C++](https://img.shields.io/badge/C++-17-00599C?logo=cplusplus)](https://isocpp.org)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-8.0-007808?logo=ffmpeg)](https://ffmpeg.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[中文](#chinese) | [English](#english)

> 🤖 **本项目 100% 由 AI 生成**

## 📸 软件预览

<table>
  <tr>
    <td align="center"><b>🎬 主界面</b></td>
    <td align="center"><b>📋 使用演示</b></td>
  </tr>
  <tr>
    <td><img src="rel/view.png" width="100%" alt="FFmpeg++ 主界面"></td>
    <td><img src="rel/view1.png" width="100%" alt="FFmpeg++ 使用演示"></td>
  </tr>
</table>

</div>

---

## 中文 <a id="chinese"></a>

### 📖 概述

FFmpeg++ 是一款基于 **Flutter**（Material Design 3 前端）+ **C++17**（DLL 后端，通过 FFI 加载）的现代化桌面视频处理工具。v3.0.0 新增蓝图式**节点编辑器**，支持构建复杂的多步骤视频处理流程。

### 🏗 架构

```
┌──────────────────────────────────┐
│   Flutter 桌面 GUI (Dart)        │  ← Material Design 3
│   Dart FFI ↔ ffmpegpp.dll        │
├──────────────────────────────────┤
│   C++17 后端 (ffmpegpp.dll)      │  ← DLL 模式（FFI 轮询）
│   subprocess → ffmpeg / ffprobe  │
├──────────────────────────────────┤
│   FFmpeg / FFprobe               │  ← 外部依赖（用户自行安装）
└──────────────────────────────────┘
```

### ✨ 功能

| 模块 | 说明 |
|------|------|
| 🎬 **项目** | 多视频导入、ffprobe 自动探测、缩略图预览 |
| 📋 **处理队列** | 顺序批量处理、实时进度解析 |
| 🧩 **节点编辑器** | 蓝图式 DAG 画布，构建复杂多步骤处理流程 |
| 🎞 **视频转码** | 17+ 编码器（H.264/H.265/AV1/VP9/SVT-AV1），GPU 加速（NVIDIA/AMD/Intel）|
| 🎵 **音频** | AAC / MP3 / Opus / Vorbis / FLAC / AC3 / PCM，自定义码率，7.1 环绕 |
| 📝 **字幕** | 烧录外挂 SRT/ASS/SSA，拾色器，系统字体选择器（含预览）|
| 📷 **帧提取** | 单帧 / 范围分帧 / 全部分帧 |
| ✂️ **片段截取** | 时间范围截取，级联时长约束 |
| 🧠 **命令** | 手动输入 ffmpeg 命令 + 快捷模板 + 参数参考 |
| ⚙️ **设置** | 暗/亮主题、字体、主题色、背景图片、编辑模式切换 |

### 🧩 节点编辑器

节点编辑器是 v3.0.0 的核心新功能。详见 **[NODE_EDITOR.md](NODE_EDITOR.md)**。

- 无限画布，支持平移缩放
- 拖拽节点，自由连线
- 右键添加节点 / 删除连线
- 自动验证（环路检测、类型冲突、时长约束）
- 智能合并：音视频处理 + 字幕 = 单条 ffmpeg 命令
- 调试覆盖层显示执行计划
- 多源文件节点 = 多个独立任务

### 📦 安装（用户）

1. 从 [Releases](https://github.com/pity-Fox/FFmpeg_plus_plus/releases) 下载 `FFmpeg++_v*_setup.exe`
2. 运行安装程序
3. 确保已安装 [FFmpeg](https://ffmpeg.org/download.html) 并加入 PATH 环境变量

### 🔧 开发

#### 环境要求
- Windows 10/11
- [Flutter SDK](https://flutter.dev) 3.44+
- Visual Studio 2022/2025，含 C++ 桌面开发工作负载
- [CMake](https://cmake.org) 3.20+
- [FFmpeg](https://ffmpeg.org) 在 PATH 中
- [Inno Setup](https://jrsoftware.org/isinfo.php) 6+（构建安装包时需要）

#### 开发模式

```bash
# 1. 编译 C++ 后端 (DLL)
cd ffmpeg_video_tool/server_cpp
cmake -S . -B build_cmake -G "Visual Studio 18 2026" -A x64
cmake --build build_cmake --config Release --target ffmpegpp

# 2. 启动 Flutter GUI
cd ../ffmpegpp_gui
flutter pub get
flutter run -d windows
```

#### 生产构建

```bash
# 1. 编译 DLL 后端
cd ffmpeg_video_tool/server_cpp
cmake -S . -B build_cmake -G "Visual Studio 18 2026" -A x64
cmake --build build_cmake --config Release --target ffmpegpp

# 2. 构建 Flutter
cd ../ffmpegpp_gui
flutter build windows --release

# 3. 组装输出
mkdir ../../build
cp -r build/windows/x64/runner/Release/* ../../build/
cp ../server_cpp/build_cmake/Release/ffmpegpp.dll ../../build/

# 4. 构建安装包
iscc ../../make/setup.iss
```

### 🛠 技术栈

| 层级 | 技术 |
|------|------|
| UI 框架 | Flutter 3.44, Material Design 3 |
| 状态管理 | Provider (ChangeNotifier) |
| 后端 | C++17, 编译为 DLL, 通过 Dart FFI 加载 |
| 视频引擎 | FFmpeg 8.0 / ffprobe |
| 安装包 | Inno Setup 6 |
| 代码生成 | 100% AI 生成（Claude）|

### ⭐ Star 历史

<a href="https://star-history.com/#pity-Fox/FFmpeg_plus_plus&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=pity-Fox/FFmpeg_plus_plus&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=pity-Fox/FFmpeg_plus_plus&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=pity-Fox/FFmpeg_plus_plus&type=Date" />
  </picture>
</a>

### 📄 许可证

MIT License — 详见 [LICENSE](LICENSE)

---

## English <a id="english"></a>

## 📸 software view

<table>
  <tr>
    <td align="center"><b>🎬 Main</b></td>
    <td align="center"><b>📋 use</b></td>
  </tr>
  <tr>
    <td><img src="rel/view.png" width="100%" alt="FFmpeg++ Main"></td>
    <td><img src="rel/view1.png" width="100%" alt="FFmpeg++ Use"></td>
  </tr>
</table>
### 📖 Overview

FFmpeg++ wraps FFmpeg's powerful command-line capabilities into an intuitive desktop GUI. Built with **Flutter** (Material Design 3 frontend) and **C++17** (DLL backend loaded via FFI), featuring a blueprint-style **node editor** for complex video processing workflows.

### 🏗 Architecture

```
┌──────────────────────────────────┐
│   Flutter Desktop GUI (Dart)     │  ← Material Design 3
│   Dart FFI ↔ ffmpegpp.dll        │
├──────────────────────────────────┤
│   C++17 Backend (ffmpegpp.dll)   │  ← DLL mode (FFI poll)
│   subprocess → ffmpeg / ffprobe  │
├──────────────────────────────────┤
│   FFmpeg / FFprobe               │  ← External dependency
└──────────────────────────────────┘
```

### ✨ Features

| Module | Description |
|--------|-------------|
| 🎬 **Projects** | Multi-video import, auto ffprobe probing, thumbnail preview |
| 📋 **Queue** | Sequential batch processing, real-time progress parsing |
| 🧩 **Node Editor** | Blueprint-style DAG canvas for complex multi-step workflows |
| 🎞 **Transcode** | 17+ codecs (H.264/H.265/AV1/VP9/SVT-AV1), GPU acceleration (NVIDIA/AMD/Intel) |
| 🎵 **Audio** | AAC / MP3 / Opus / Vorbis / FLAC / AC3 / PCM, custom bitrate, 7.1 surround |
| 📝 **Subtitles** | Burn-in external SRT/ASS/SSA, color picker, system font selector with preview |
| 📷 **Frames** | Single frame / range / full video decomposition |
| ✂️ **Clipping** | Time-range extraction with cascading duration constraints |
| 🧠 **Command** | Manual ffmpeg command input with templates & parameter reference |
| ⚙️ **Settings** | Dark/Light theme, fonts, accent colors, background image, editor mode toggle |

### 🧩 Node Editor

The node editor is the signature feature of v3.0.0. See **[NODE_EDITOR.md](NODE_EDITOR.md)** for full documentation.

- Infinite canvas with pan & zoom
- Drag-and-drop nodes, freeform connections
- Right-click to add nodes, right-click connections to delete
- Automatic validation (cycle detection, type conflicts, duration constraints)
- Smart merge: AV processing + subtitle burn = single ffmpeg command
- Debug overlay showing execution plan
- Multiple source nodes = multiple independent tasks

### 📦 Installation (Users)

1. Download the latest `FFmpeg++_v*_setup.exe` from [Releases](https://github.com/pity-Fox/FFmpeg_plus_plus/releases)
2. Run the installer
3. Make sure [FFmpeg](https://ffmpeg.org/download.html) is installed and in your PATH

### 🔧 Development

#### Prerequisites
- Windows 10/11
- [Flutter SDK](https://flutter.dev) 3.44+
- Visual Studio 2022/2025 with C++ Desktop workload
- [CMake](https://cmake.org) 3.20+
- [FFmpeg](https://ffmpeg.org) in PATH
- [Inno Setup](https://jrsoftware.org/isinfo.php) 6+ (for installer)

#### Quick Start

```bash
# 1. Build C++ backend (DLL)
cd ffmpeg_video_tool/server_cpp
cmake -S . -B build_cmake -G "Visual Studio 18 2026" -A x64
cmake --build build_cmake --config Release --target ffmpegpp

# 2. Run Flutter GUI
cd ../ffmpegpp_gui
flutter pub get
flutter run -d windows
```

#### Production Build

```bash
# 1. Build DLL backend
cd ffmpeg_video_tool/server_cpp
cmake -S . -B build_cmake -G "Visual Studio 18 2026" -A x64
cmake --build build_cmake --config Release --target ffmpegpp

# 2. Build Flutter
cd ../ffmpegpp_gui
flutter build windows --release

# 3. Assemble
mkdir ../../build
cp -r build/windows/x64/runner/Release/* ../../build/
cp ../server_cpp/build_cmake/Release/ffmpegpp.dll ../../build/

# 4. Build installer
iscc ../../make/setup.iss
```

### 📁 Project Structure

```
ffmpeg++
├── make/                           # Installer resources
│   ├── app_icon.ico                # Application icon
│   └── setup.iss                   # Inno Setup script
├── build/                          # Assembled output
│   ├── ffmpegpp_gui.exe            # Flutter GUI
│   ├── ffmpegpp.dll                # C++ backend (DLL)
│   └── data/                       # Flutter AOT assets
├── ffmpeg_video_tool/
│   ├── server_cpp/                 # C++17 backend
│   │   ├── src/                    # Source files
│   │   ├── include/                # Headers (nlohmann/json)
│   │   └── CMakeLists.txt          # CMake build
│   └── ffmpegpp_gui/               # Flutter desktop app
│       └── lib/
│           ├── models/             # Data models (PipelineGraph, etc.)
│           ├── services/           # Backend client, graph executor
│           ├── providers/          # AppState
│           ├── pages/              # Pages (Projects/Queue/Command/Settings)
│           └── widgets/            # Node editor, step editors
├── NODE_EDITOR.md                  # Node editor documentation
└── README.md
```

### 🛠 Tech Stack

| Layer | Technology |
|-------|-----------|
| UI Framework | Flutter 3.44, Material Design 3 |
| State Management | Provider (ChangeNotifier) |
| Backend | C++17, compiled to DLL, loaded via Dart FFI |
| Video Engine | FFmpeg 8.0 / ffprobe |
| Installer | Inno Setup 6 |
| Code Generation | 100% AI-generated via Claude |

### ⭐ Star History

<a href="https://star-history.com/#pity-Fox/FFmpeg_plus_plus&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=pity-Fox/FFmpeg_plus_plus&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=pity-Fox/FFmpeg_plus_plus&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=pity-Fox/FFmpeg_plus_plus&type=Date" />
  </picture>
</a>

---

<div align="center">
  <sub>🤖 100% AI-Generated — Built with Flutter + C++ + FFmpeg + Claude</sub>
</div>
