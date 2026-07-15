# 🎬 FFmpeg++

<div align="center">

**专业视频 / 图片 / 音频处理桌面应用 — 100% AI 生成代码**

[![Platform](https://img.shields.io/badge/platform-Windows%20|%20Linux%20|%20macOS-blue?logo=flutter)](https://flutter.dev)
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

FFmpeg++ 是一款基于 **Flutter**（Material Design 3 前端）+ **C++17**（共享库后端，通过 FFI 加载）的跨平台桌面视频/图片/音频处理工具。核心功能为蓝图式**节点编辑器**，支持构建复杂的多步骤处理流程。

支持 **Windows**、**Linux**（x64 / ARM64）、**macOS**（Universal）三大平台。

### 🏗 架构

```
┌──────────────────────────────────┐
│   Flutter 桌面 GUI (Dart)        │  ← Material Design 3
│   Dart FFI ↔ libffmpegpp         │
├──────────────────────────────────┤
│   C++17 后端 (dll/so/dylib)      │  ← 共享库模式（FFI 轮询）
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
| 🧩 **节点编辑器** | 蓝图式 DAG 画布，25+ 节点类型，构建复杂多步骤处理流程 |
| 🎞 **视频转码** | 17+ 编码器（H.264/H.265/AV1/VP9/SVT-AV1），GPU 加速（NVIDIA/AMD/Intel）|
| 🎵 **音频处理** | 转码 / 变速 / 音量调整 / 动态压缩 / 元信息编辑 / 提取音频（带预览播放）|
| 📝 **字幕** | 烧录外挂 SRT/ASS/SSA，拾色器，系统字体选择器（含预览）|
| 📷 **帧提取** | 单帧 / 范围分帧 / 全部分帧 |
| ✂️ **片段截取** | 时间范围截取，级联时长约束 |
| 🖼 **图片处理** | 格式转换 / 裁剪 / 旋转 / 缩放 / 亮度 / 噪点 / 锐化 / 降噪 / 通道提取 |
| 🎬 **视频裁剪** | 交互式选区工具，支持多选区、拖拽调整、保留/移除模式 |
| 🔗 **合并媒体** | 多文件顺序合并，图片序列合成视频 |
| 🧠 **命令** | 手动输入 ffmpeg 命令 + 快捷模板 + 参数参考 |
| 🤖 **AI 助手** | 内置 AI 聊天面板，自然语言描述需求自动配置节点 |
| ⚙️ **设置** | 暗/亮主题、字体、主题色、背景图片、编辑模式切换 |

### 🧩 节点编辑器

节点编辑器是 FFmpeg++ 的核心。详见 **[NODE_EDITOR.md](NODE_EDITOR.md)**。

- 无限画布，支持平移缩放
- 拖拽节点，自由连线
- 右键添加节点 / 删除连线
- 25+ 节点类型覆盖视频、音频、图片处理
- 自动验证（环路检测、类型冲突、时长约束）
- 智能合并：音视频处理 + 字幕 = 单条 ffmpeg 命令
- 逻辑块：循环处理支持
- 调试覆盖层显示执行计划
- 多源文件节点 = 多个独立任务

### 📦 安装

| 平台 | 下载 |
|------|------|
| **Windows** | [Releases](https://github.com/pity-Fox/FFmpeg_plus_plus/releases) → `FFmpeg++_v*_setup.exe` |
| **Linux x64** | [Releases](https://github.com/pity-Fox/FFmpeg_plus_plus/releases) → `ffmpegpp_*_amd64.deb` |
| **Linux ARM64** | [Releases](https://github.com/pity-Fox/FFmpeg_plus_plus/releases) → `ffmpegpp_*_arm64.deb` |
| **macOS** | [Releases](https://github.com/pity-Fox/FFmpeg_plus_plus/releases) → `FFmpeg++_v*_macOS.dmg` |

> 确保已安装 [FFmpeg](https://ffmpeg.org/download.html) 并加入 PATH 环境变量。

### 🔧 开发

#### 环境要求
- [Flutter SDK](https://flutter.dev) 3.44+
- [CMake](https://cmake.org) 3.20+
- [FFmpeg](https://ffmpeg.org) 在 PATH 中
- **Windows**: Visual Studio 2022/2025，含 C++ 桌面开发工作负载；[Inno Setup](https://jrsoftware.org/isinfo.php) 6+
- **Linux**: `cmake g++ libgtk-3-dev pkg-config ninja-build`
- **macOS**: Xcode Command Line Tools

#### 开发模式

```bash
# 1. 编译 C++ 后端
cd server_cpp
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)    # Linux/macOS
# Windows: cmake --build . --config Release

# 2. 启动 Flutter GUI
cd ../../ffmpegpp_gui
flutter pub get
flutter run -d linux   # 或 -d windows / -d macos
```

### 🛠 技术栈

| 层级 | 技术 |
|------|------|
| UI 框架 | Flutter 3.44, Material Design 3 |
| 状态管理 | Provider (ChangeNotifier) |
| 后端 | C++17, 编译为共享库 (dll/so/dylib), 通过 Dart FFI 加载 |
| 视频引擎 | FFmpeg 8.0 / ffprobe |
| 音频预览 | just_audio (GStreamer on Linux) |
| 安装包 | Inno Setup (Windows) / dpkg-deb (Linux) / hdiutil (macOS) |
| CI/CD | GitHub Actions — Windows / Linux x64 / Linux ARM64 / macOS |
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

## 📸 Software Preview

<table>
  <tr>
    <td align="center"><b>🎬 Main</b></td>
    <td align="center"><b>📋 Demo</b></td>
  </tr>
  <tr>
    <td><img src="rel/view.png" width="100%" alt="FFmpeg++ Main"></td>
    <td><img src="rel/view1.png" width="100%" alt="FFmpeg++ Demo"></td>
  </tr>
</table>

### 📖 Overview

FFmpeg++ is a cross-platform desktop tool for video, image, and audio processing. Built with **Flutter** (Material Design 3 frontend) and **C++17** (shared library backend via FFI), featuring a blueprint-style **node editor** with 25+ node types for complex processing workflows.

Supports **Windows**, **Linux** (x64 / ARM64), and **macOS** (Universal).

### 🏗 Architecture

```
┌──────────────────────────────────┐
│   Flutter Desktop GUI (Dart)     │  ← Material Design 3
│   Dart FFI ↔ libffmpegpp         │
├──────────────────────────────────┤
│   C++17 Backend (dll/so/dylib)   │  ← Shared lib (FFI poll)
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
| 🧩 **Node Editor** | Blueprint-style DAG canvas, 25+ node types for complex workflows |
| 🎞 **Transcode** | 17+ codecs (H.264/H.265/AV1/VP9/SVT-AV1), GPU acceleration (NVIDIA/AMD/Intel) |
| 🎵 **Audio** | Transcode / speed / volume / dynamic compressor / metadata / extract audio (with playback preview) |
| 📝 **Subtitles** | Burn-in external SRT/ASS/SSA, color picker, system font selector with preview |
| 📷 **Frames** | Single frame / range / full video decomposition |
| ✂️ **Clipping** | Time-range extraction with cascading duration constraints |
| 🖼 **Image** | Format convert / crop / rotate / scale / brightness / noise / sharpen / denoise / channel extract |
| 🎬 **Video Crop** | Interactive selection tool with multi-region, drag-resize, keep/remove modes |
| 🔗 **Concat** | Multi-file sequential merge, image sequence to video |
| 🧠 **Command** | Manual ffmpeg command input with templates & parameter reference |
| 🤖 **AI Assistant** | Built-in AI chat panel, describe what you want in natural language |
| ⚙️ **Settings** | Dark/Light theme, fonts, accent colors, background image, editor mode toggle |

### 🧩 Node Editor

The node editor is the core of FFmpeg++. See **[NODE_EDITOR.md](NODE_EDITOR.md)** for full documentation.

- Infinite canvas with pan & zoom
- Drag-and-drop nodes, freeform connections
- Right-click to add nodes, right-click connections to delete
- 25+ node types covering video, audio, and image processing
- Automatic validation (cycle detection, type conflicts, duration constraints)
- Smart merge: AV processing + subtitle burn = single ffmpeg command
- Logic blocks: loop processing support
- Debug overlay showing execution plan
- Multiple source nodes = multiple independent tasks

### 📦 Installation

| Platform | Download |
|----------|----------|
| **Windows** | [Releases](https://github.com/pity-Fox/FFmpeg_plus_plus/releases) → `FFmpeg++_v*_setup.exe` |
| **Linux x64** | [Releases](https://github.com/pity-Fox/FFmpeg_plus_plus/releases) → `ffmpegpp_*_amd64.deb` |
| **Linux ARM64** | [Releases](https://github.com/pity-Fox/FFmpeg_plus_plus/releases) → `ffmpegpp_*_arm64.deb` |
| **macOS** | [Releases](https://github.com/pity-Fox/FFmpeg_plus_plus/releases) → `FFmpeg++_v*_macOS.dmg` |

> Make sure [FFmpeg](https://ffmpeg.org/download.html) is installed and in your PATH.

### 🔧 Development

#### Prerequisites
- [Flutter SDK](https://flutter.dev) 3.44+
- [CMake](https://cmake.org) 3.20+
- [FFmpeg](https://ffmpeg.org) in PATH
- **Windows**: Visual Studio 2022/2025 with C++ Desktop workload; [Inno Setup](https://jrsoftware.org/isinfo.php) 6+
- **Linux**: `cmake g++ libgtk-3-dev pkg-config ninja-build`
- **macOS**: Xcode Command Line Tools

#### Quick Start

```bash
# 1. Build C++ backend
cd server_cpp
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)    # Linux/macOS
# Windows: cmake --build . --config Release

# 2. Run Flutter GUI
cd ../../ffmpegpp_gui
flutter pub get
flutter run -d linux   # or -d windows / -d macos
```

### 🛠 Tech Stack

| Layer | Technology |
|-------|-----------|
| UI Framework | Flutter 3.44, Material Design 3 |
| State Management | Provider (ChangeNotifier) |
| Backend | C++17, compiled to shared lib (dll/so/dylib), loaded via Dart FFI |
| Video Engine | FFmpeg 8.0 / ffprobe |
| Audio Preview | just_audio (GStreamer on Linux) |
| Installer | Inno Setup (Windows) / dpkg-deb (Linux) / hdiutil (macOS) |
| CI/CD | GitHub Actions — Windows / Linux x64 / Linux ARM64 / macOS |
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
