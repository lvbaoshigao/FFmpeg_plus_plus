# 🎬 FFmpeg++

<div align="center">

**蓝图式节点化音视频处理桌面应用 — 把复杂的 FFmpeg 变成看得见的工作流**

[![Platform](https://img.shields.io/badge/platform-Windows%20|%20Linux%20|%20macOS-blue?logo=flutter)](https://flutter.dev)
[![Flutter](https://img.shields.io/badge/Flutter-3.44+-02569B?logo=flutter)](https://flutter.dev)
[![C++](https://img.shields.io/badge/C++-17-00599C?logo=cplusplus)](https://isocpp.org)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-8.0-007808?logo=ffmpeg)](https://ffmpeg.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README_EN.md) | 简体中文

>  **本项目由 AI 生成绝大多数代码，并由人类主导完成**

</div>

---

## 📖 概述

**FFmpeg++** 是一款跨平台的视频 / 图片 / 音频处理工具，用一套**蓝图式节点编辑器**取代了记忆
命令行参数的负担：在无限画布上摆放「开始 → 处理 → 输出」节点、连线成图，应用会自动校验图结构
并生成对应的 `ffmpeg` 命令去执行。

界面基于 **Flutter** 与 Material Design 3 构建，底层处理内核是 **C++17** 共享库，通过 Dart FFI
调用；真正的编解码仍交给 **FFmpeg / ffprobe** 完成 —— 所以它既保留了 FFmpeg 的能力，又不需要你
去查手册。

### 它解决什么问题

- **命令太长**：滤镜、编码器、映射、字幕烧录的参数组合动辄几十个开关，手写容易出错。
- **重复劳动**：同一套处理流程要套用到大量文件，靠脚本维护成本高。
- **过程不直观**：一条长长的命令看不出「先做了什么、后做了什么」。

节点化之后，处理流程变成了可视、可保存、可复用、可分享的图。

### 三种使用方式

| 方式 | 适合场景 |
|------|----------|
| 🧩 **节点编辑器** | 多步骤、多分支的复杂流程：转码 + 滤镜 + 字幕 + 音频处理串成一张图 |
| 🎚 **快捷配置** | 单文件快速处理：在预设面板里选好参数，直接入队 |
| 🧠 **命令模式** | 需要完全自由：手写 ffmpeg 命令，带模板与参数参考 |

---

## 📸 软件概览

### 主界面

<img src="make/1.jpg" alt="FFmpeg++ 主界面" width="100%">

项目页是整个应用的入口：左侧导航在「项目 / 处理队列 / 命令 / 配置库 / 设置」之间切换；
媒体以卡片形式陈列，支持拖放导入、缩略图预览、ffprobe 自动探测（编码、分辨率、时长、码率）。
选中文件即可进入节点编辑器，或直接用快捷配置套用预设；处理任务统一进入队列。

### 节点编辑器

<img src="make/2.jpg" alt="FFmpeg++ 节点编辑器" width="100%">

节点编辑器是核心工作区：顶部工具栏负责保存、撤销、重做、自动排版与调试视图；
中间是无限画布，节点用端口连线，右键即可增删；右侧跟随选中节点展开参数面板。
画布上的每一步都会被翻译成实际执行的 ffmpeg 调用，执行前先做完整校验。

---

##  节点编辑器：怎么用


### 第一步：摆放节点

从工具栏或右键菜单把处理节点放到画布上。每条流程以 **开始节点** 起步、以 **输出节点** 收尾，
中间按需要插入处理节点：

- **转码与滤镜**：视频转码（编码器 / 码率 / CRF / 分辨率 / 帧率）、视频滤镜（亮度、对比度、
  饱和度、伽马、色相、暗角、降噪、锐化、黑白）、画面变换（缩放 / 翻转 / 旋转）、画面叠加
  （水印 / Logo，五档定位 + 透明度 + 缩放 + 边距）。
- **音频**：转码、变速、音量、动态压缩、淡入淡出、元信息、提取音频。
- **图像**：格式转换、裁剪、旋转、缩放、亮度、调整（饱和度 · 伽马 · 对比度）、噪点、锐化、
  降噪、通道提取。
- **节奏与裁切**：变速、时间范围截取、单帧 / 范围分帧 / 全部分帧、交互式画面裁剪。
- **组合**：多文件拼接、图片序列合成视频、字幕烧录（SRT / ASS / SSA，带拾色器与字体选择器）。

### 第二步：连线成图

拖动端口连线，把「上一步的输出」接到「下一步的输入」。编辑器会持续校验这张图：

- 环路检测、连线类型冲突、悬空节点、缺少开始 / 输出节点；
- 时长约束（例如截取时长与后续节点不匹配时会作出提示）；
- 多个可合并的节点会被自动坍缩成 **一条 ffmpeg 命令**，而不是多次重编码。

**逻辑块与逻辑门** 让流程图不只是一条直线：循环块可以按次数或条件反复执行一段子链；
与 / 或 / 非 / 与非 / 或非 / 异或 / 同或门、恒 1 / 恒 0、时间触发器可作为「使能端 / 状态端」
控制某些处理节点是否生效 —— 相当于给处理流程加上了条件分支能力。

### 第三步：执行与复用

一个 **源文件节点** 对应一个独立任务，因此同一张图可以批量套用到多个文件上，任务按顺序在
处理队列中执行，进度、速度、剩余时间实时回显。

图建立好之后可以存进 **配置库**，导出为 `.fppx` 工程文件分发给他人；再次导入时会自动校验配置
与你的软件版本、媒体类型是否匹配。

---

##  支持的额外功能

### 🤖 AI 助手

应用内置 AI 对话面板，可以直接用自然语言描述需求（例如「把这个视频压到更小的体积，顺便加水印」），
由 AI 生成或修改画布上的节点与参数，无需手动摆放。

支持 **OpenAI 协议** 与 **Anthropic 协议** 两类接口，可配置多个模型档案、多 API Key 轮换；
密钥在本地加密存储。

###  MCP 服务（Model Context Protocol）

FFmpeg++ 内置一个 MCP HTTP 服务器（**默认关闭**），可把整个应用接入 AI 客户端与自动化工作流：

- **端点**：`http://127.0.0.1:<端口>/`，JSON-RPC 2.0 over HTTP POST，支持批量请求与协议版本协商；
- **工具（27 个）**：画布操作（`add_node` / `connect_nodes` / `modify_node_params` / `undo` /
  `save` / `rename_node` …）、读取（`list_nodes` / `list_connections` / `get_graph_stats` /
  `error_check`）、媒体与文件（`probe_video` / `list_directory` / `read_file_info`）、
  任务（`list_tasks` / `get_task_info` / `cancel_tasks`）、逻辑门（`add_gate` / `set_gate_params`）、
  容器（`list_containers` / `get_container_pipeline`）等；
- **资源（3 个）**：`pipeline://current`、`videos://loaded`、`tasks://all`；
- **权限开关**：允许写入（默认关，关闭时一切修改类工具被拒绝）、允许文件系统访问
  （默认开，控制目录枚举 / 文件信息 / 媒体探测 / 日志读取）；
- **安全**：默认只监听 `127.0.0.1`；改为 `0.0.0.0` 会暴露到局域网，此时强制校验访问令牌
  （请求头 `x-mcp-token` 或 `Authorization: Bearer <token>`，令牌在设置页展示）。

> 主流桌面 MCP 客户端使用 stdio 传输，如需接入请通过 `mcp-proxy` 一类的 HTTP ↔ stdio 桥接工具转发。

### 📱 Android 移动端

同一套代码也构建了 Android 版本（arm64-v8a，Android 8.0+），并针对触屏做了适配：

- 侧边栏改为底部液态玻璃导航栏，胶囊遮罩可拖动选择；
- Android 8.1+ 支持 Monet 动态取色，跟随系统壁纸生成 Material You 配色；
- **内置 ffmpeg / ffprobe** 静态可执行文件随 APK 打包，无需安装任何外部依赖；
- GPU 硬编码器不可用，自动回退 CPU 编码。

### 🛠 其它细节

- **界面**：深色 / 浅色主题、主题色、背景图片、多种表面样式（液态玻璃 / 模糊 / 纯色）、
  字体与字号、快捷键自定义、中英文界面；
- **FFmpeg 安装助手**：内置引导，Windows 走 winget，Linux 走 apt / dnf / pacman，
  macOS 走 Homebrew，也支持从压缩包导入；
- **编辑体验**：画布自动排版、撤销 / 重做、自动保存、调试覆盖层显示执行计划；
- **处理队列**：顺序批量执行、结果持久化、单任务取消与「停止所有」；
- **应用更新**：内置更新检查与下载安装（校验 SHA-256）。

---

## 📦 下载与安装

FFmpeg++ 支持以下客户端：

| 平台 | 架构 | 安装包 |
|------|------|--------|
| **Windows** | x64 | `FFmpeg++_v*_setup.exe` |
| **Linux** | x64 | `ffmpegpp_*_amd64.deb` |
| **Linux** | ARM64 | `ffmpegpp_*_arm64.deb` |
| **macOS** | Universal（Intel + Apple Silicon） | `FFmpeg++_v*_macOS.dmg` |
| **Android** | arm64-v8a | `app-release.apk` |

### ⬇️ 前往下载

**➡️ [GitHub Releases（全部平台安装包）](https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases)**

在 Release 页面的 **Assets** 区域选择上表中对应的文件即可。Windows 安装包内置简繁中文与英文
安装向导；`.deb` 可使用 `sudo dpkg -i` 或 `sudo apt install ./*.deb` 安装。

> **关于 FFmpeg 依赖**：桌面端首次启动若未检测到 `ffmpeg` / `ffprobe`，应用会引导你一键安装
> （winget / apt / dnf / pacman / Homebrew）或从已有压缩包导入；Android 版已内置，无需任何操作。

---

## ⭐ 星标历史

<a href="https://star-history.com/#lvbaoshigao/FFmpeg_plus_plus&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=lvbaoshigao/FFmpeg_plus_plus&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=lvbaoshigao/FFmpeg_plus_plus&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=lvbaoshigao/FFmpeg_plus_plus&type=Date" />
  </picture>
</a>

---

## 🔧 从源码构建（开发者）

<details>
<summary>展开查看环境要求、构建步骤与技术栈</summary>

### 架构

```
┌──────────────────────────────────┐
│   Flutter GUI (Dart)             │  ← Material Design 3
│   Dart FFI ↔ libffmpegpp         │
├──────────────────────────────────┤
│   C++17 后端 (dll / so / dylib)  │  ← 共享库，消息队列轮询
│   subprocess → ffmpeg / ffprobe  │
├──────────────────────────────────┤
│   FFmpeg / FFprobe               │  ← 外部进程
└──────────────────────────────────┘
```

### 环境要求

- [Flutter SDK](https://flutter.dev) 3.44+
- [CMake](https://cmake.org) 3.20+
- **Windows**：Visual Studio 2022/2025（C++ 桌面开发负载）、[Inno Setup](https://jrsoftware.org/isinfo.php) 6+
- **Linux**：`cmake g++ libgtk-3-dev pkg-config ninja-build`
- **macOS**：Xcode Command Line Tools
- **Android**：Android SDK + NDK 28.2 + JDK 17+

### 手动构建

```bash
# 1. 编译 C++ 后端
cd server_cpp
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)                 # Linux / macOS
# Windows: cmake .. -G "NMake Makefiles" && nmake

# 2. 运行 Flutter GUI
cd ../../ffmpegpp_gui
flutter pub get
flutter run -d linux            # 或 -d windows / -d macos
```

### 一键构建脚本

构建脚本集中在 `build/` 目录，详见 [`build/README.md`](build/README.md)：

```bash
build/build_all.sh all          # 桌面端 + Android APK
build/build_all.sh desktop      # 仅桌面端
build/build_all.sh android      # 仅 Android APK
```

构建产物：

| 平台 | 路径 |
|------|------|
| Windows | `ffmpegpp_gui/build/windows/x64/runner/Release/` |
| Linux | `ffmpegpp_gui/build/linux/x64/release/bundle/` |
| Android | `ffmpegpp_gui/build/app/outputs/flutter-apk/app-release.apk` |

### 目录结构

```
FFmpeg_plus_plus/
├── ffmpegpp_gui/     # Flutter 前端（UI、状态管理、节点编辑器、MCP 服务）
├── server_cpp/       # C++17 后端（命令生成、进程调度、.fppx 编解码、音视频探测）
├── build/            # 统一构建脚本（桌面端 / Android）
├── make/             # 安装器脚本与图标资源
└── .github/          # GitHub Actions 发布流水线
```

### 技术栈

| 层级 | 技术 |
|------|------|
| UI 框架 | Flutter 3.44 · Material Design 3 |
| 状态管理 | Provider（ChangeNotifier） |
| 后端 | C++17 共享库（dll / so / dylib），Dart FFI 加载 |
| 处理引擎 | FFmpeg 8.0 / ffprobe（子进程） |
| 音频预览 | just_audio（Linux 上为 GStreamer） |
| 安装包 | Inno Setup（Windows）· dpkg-deb（Linux）· hdiutil（macOS） |
| CI/CD | GitHub Actions — Windows / Linux x64 / Linux ARM64 / macOS / Android |

</details>

---

<div align="center">

<sub>  AI-Wrote code and desion by human — Built with Flutter + C++ + FFmpeg</sub>

MIT License — 详见 [LICENSE](LICENSE)

</div>
