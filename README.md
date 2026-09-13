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
| 🧩 **节点编辑器** | 蓝图式 DAG 画布，30 节点类型，构建复杂多步骤处理流程 |
| 🎞 **视频转码** | 17+ 编码器（H.264/H.265/AV1/VP9/SVT-AV1），GPU 加速（NVIDIA/AMD/Intel）|
| ✨ **视频滤镜** | 调色增强多选合并：亮度 / 对比度 / 饱和度 / 伽马 / 色相 / 暗角 / 降噪 / 锐化 / 黑白 |
| 📐 **画面变换** | 缩放（宽/高/百分比）/ 翻转 / 旋转，任意链路位置生效 |
| 📚 **画面叠加** | 水印 / Logo 叠加，五档定位 + 透明度 + 缩放 + 边距 |
| 🎵 **音频处理** | 转码 / 变速 / 音量调整 / 动态压缩 / 元信息编辑 / 提取音频（带预览播放）/ 淡入淡出 |
| 📝 **字幕** | 烧录外挂 SRT/ASS/SSA，拾色器，系统字体选择器（含预览）|
| 📷 **帧提取** | 单帧 / 范围分帧 / 全部分帧 |
| ✂️ **片段截取** | 时间范围截取，级联时长约束 |
| 🖼 **图片处理** | 格式转换 / 裁剪 / 旋转 / 缩放 / 亮度 / 调整（饱和度·伽马·对比度）/ 噪点 / 锐化 / 降噪 / 通道提取 |
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
- 30 节点类型覆盖视频、音频、图片处理
- 自动验证（环路检测、类型冲突、时长约束）
- 智能合并：音视频处理 + 字幕 = 单条 ffmpeg 命令
- 逻辑块：循环处理支持
- 调试覆盖层显示执行计划
- 多源文件节点 = 多个独立任务

### 🤖 MCP 服务

FFmpeg++ 内置 MCP（Model Context Protocol）HTTP 服务器，可把本应用接入支持 MCP 的 AI 客户端 / 自动化工作流：

- **开启**：设置 → MCP / AI → 启用 MCP 服务（默认关闭）
- **端点**：`http://127.0.0.1:<端口>/`，JSON-RPC 2.0 over HTTP POST（支持批量请求、协议版本协商）
- **工具**（28 个）：画布操作（add_node / connect_nodes / modify_node_params / undo / save …）、
  文件与媒体读取（list_directory / read_file_info / probe_video）、任务查询（list_tasks / get_task_info / cancel_tasks）、
  逻辑门（add_gate / set_gate_types）等
- **资源**（3 个）：`pipeline://current`、`videos://loaded`、`tasks://all`
- **权限开关**：允许写入（默认关，写操作全部拒绝）、允许文件系统访问（默认开，可单独关闭列目录/文件信息/媒体探测）
- **安全**：默认仅监听 `127.0.0.1`（本机回环，无需令牌）；监听地址改为 `0.0.0.0` 可暴露到局域网，
  此时强制校验访问令牌（请求头 `x-mcp-token` 或 `Authorization: Bearer <token>`，令牌在设置页显示）
- **注意**：Claude Desktop / Cursor 等主流 MCP 客户端使用 stdio 传输，如需接入请经 HTTP↔stdio 桥接工具（如 `mcp-proxy`）转发

### 📦 安装

| 平台 | 下载 |
|------|------|
| **Windows** | [Releases](https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases) → `FFmpeg++_v*_setup.exe` |
| **Linux x64** | [Releases](https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases) → `ffmpegpp_*_amd64.deb` |
| **Linux ARM64** | [Releases](https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases) → `ffmpegpp_*_arm64.deb` |
| **macOS** | [Releases](https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases) → `FFmpeg++_v*_macOS.dmg` |

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

#### 🤖 Android 移动端

移动端适配只影响 Android 平台，桌面端行为不变：

- **底部液态玻璃导航栏**：PC 左侧边栏在移动端移至底部，选中项为可拖动
  胶囊遮罩（水平拖动 → 松手吸附最近项并跳转，逻辑与 PC 侧边栏一致）。
- **命令 / 日志移入设置**：底部栏只保留 项目 / 处理队列 / 配置库 / 设置，
  命令与日志在 设置 → 工具 中进入。
- **Monet 动态取色**：Android 8.1+ 跟随系统壁纸生成 Material You 配色
  （设置 → 外观 → 动态取色 可关闭），参考 Android 16 莫奈风格。
- **内置 FFmpeg**：ffmpeg / ffprobe 以 arm64 静态可执行文件打包进 APK
  （jniLibs），C++ 后端通过子进程调用，无需用户安装任何东西。
- **触屏适配**：项目页禁用桌面拖放、节点编辑器顶部返回栏、状态栏/手势
  区安全边距等。

构建 APK（需 Android SDK + NDK r26d + JDK 17+）：

```bash
# 一键构建全部（桌面端 + Android APK）
build/build_all.sh all

# 只构建 Android APK（自动修补 file_picker compileSdk、自动重试防 OOM）
build/build_all.sh android

# 分步：先交叉编译内置 ffmpeg/ffprobe + C++ 后端（产物在缓存根 dist/）
build/android/build_ffmpeg.sh
# 再构建 APK
build/android/build_apk.sh

# 产物: ffmpegpp_gui/build/app/outputs/flutter-apk/app-release.apk (arm64-v8a)
```

> 构建脚本集中在 `build/`（详见 `build/README.md`）：代码在仓库、缓存/工具链在
> sdb2，路径均可通过 `FFMPEGPP_CACHE`/`FFMPEGPP_ROOT` 等环境变量覆盖。

> 说明：桌面端更新机制/安装器不适用于移动端，设置页已做对应隐藏与提示；
> GPU 硬编码器（NVIDIA/AMD/Intel）在 Android 上不可用，自动回退 CPU 编码。

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

<a href="https://star-history.com/#lvbaoshigao/FFmpeg_plus_plus&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=lvbaoshigao/FFmpeg_plus_plus&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=lvbaoshigao/FFmpeg_plus_plus&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=lvbaoshigao/FFmpeg_plus_plus&type=Date" />
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
| 🧩 **Node Editor** | Blueprint-style DAG canvas, 30 node types for complex workflows |
| 🎞 **Transcode** | 17+ codecs (H.264/H.265/AV1/VP9/SVT-AV1), GPU acceleration (NVIDIA/AMD/Intel) |
| ✨ **Video Filters** | Merged color grading: brightness / contrast / saturation / gamma / hue / vignette / denoise / sharpen / grayscale |
| 📐 **Geometry** | Scale (width/height/percent) / flip / rotate at any point in the chain |
| 📚 **Overlay** | Watermark / logo with 5-position placement, opacity, scale, margin |
| 🎵 **Audio** | Transcode / speed / volume / dynamic compressor / metadata / extract audio (with playback preview) / fade in-out |
| 📝 **Subtitles** | Burn-in external SRT/ASS/SSA, color picker, system font selector with preview |
| 📷 **Frames** | Single frame / range / full video decomposition |
| ✂️ **Clipping** | Time-range extraction with cascading duration constraints |
| 🖼 **Image** | Format convert / crop / rotate / scale / brightness / adjust (saturation·gamma·contrast) / noise / sharpen / denoise / channel extract |
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
- 30 node types covering video, audio, and image processing
- Automatic validation (cycle detection, type conflicts, duration constraints)
- Smart merge: AV processing + subtitle burn = single ffmpeg command
- Logic blocks: loop processing support
- Debug overlay showing execution plan
- Multiple source nodes = multiple independent tasks

### 🤖 MCP Server

FFmpeg++ ships with a built-in MCP (Model Context Protocol) HTTP server so AI clients / automation workflows can drive the app:

- **Enable**: Settings → MCP / AI → Enable MCP Server (off by default)
- **Endpoint**: `http://127.0.0.1:<port>/`, JSON-RPC 2.0 over HTTP POST (batch requests & protocol-version negotiation supported)
- **Tools** (28): canvas operations (add_node / connect_nodes / modify_node_params / undo / save …),
  file & media reads (list_directory / read_file_info / probe_video), task queries (list_tasks / get_task_info / cancel_tasks),
  logic gates (add_gate / set_gate_params), etc.
- **Resources** (3): `pipeline://current`, `videos://loaded`, `tasks://all`
- **Permission switches**: Allow Write (off by default — all write tools rejected), Allow File Access
  (on by default; gates list_directory / read_file_info / probe_video)
- **Security**: binds `127.0.0.1` only by default (loopback, no token). Set the bind host to `0.0.0.0`
  to expose it on the LAN — an access token is then enforced (`x-mcp-token` header or `Authorization: Bearer <token>`, shown in Settings)
- **Note**: mainstream MCP desktop clients (Claude Desktop / Cursor) speak stdio; bridge via an HTTP↔stdio proxy (e.g. `mcp-proxy`) if needed

### 📦 Installation

| Platform | Download |
|----------|----------|
| **Windows** | [Releases](https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases) → `FFmpeg++_v*_setup.exe` |
| **Linux x64** | [Releases](https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases) → `ffmpegpp_*_amd64.deb` |
| **Linux ARM64** | [Releases](https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases) → `ffmpegpp_*_arm64.deb` |
| **macOS** | [Releases](https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases) → `FFmpeg++_v*_macOS.dmg` |

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

<a href="https://star-history.com/#lvbaoshigao/FFmpeg_plus_plus&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=lvbaoshigao/FFmpeg_plus_plus&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=lvbaoshigao/FFmpeg_plus_plus&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=lvbaoshigao/FFmpeg_plus_plus&type=Date" />
  </picture>
</a>

---

<div align="center">
  <sub>🤖 100% AI-Generated — Built with Flutter + C++ + FFmpeg + Claude</sub>
</div>
