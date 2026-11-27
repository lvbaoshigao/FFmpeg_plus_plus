# 1.3 下载与首次启动

首次使用前，应安装与系统平台、处理器架构匹配的软件包，并验证原生后端、FFmpeg 与 ffprobe 的可用性。

## 选择安装包

打开[项目 Releases](https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases)，在对应版本的 Assets 中按平台与架构选择安装包。文件名中的版本号随发布版本变化。

| 系统 | 安装包 | 说明 |
| --- | --- | --- |
| Windows x64 | `FFmpeg++_v*_setup.exe` | 使用安装向导 |
| Linux x64 | `*_amd64.deb` | amd64 即 x86_64 架构 |
| Linux ARM64 | `*_arm64.deb` | 适用于 ARM64，与 amd64 不兼容 |
| macOS | `*_macOS.dmg` | 仓库发布流程构建 Universal 包 |
| Android | `app-release.apk` | 当前只打包 arm64-v8a，最低 Android 8.0 |

上表列出仓库配置的发布目标。各版本提供的安装包以该次 Release 实际上传的附件为准。

### Linux 安装示例

在下载目录中执行以下命令，并将示例包名替换为已下载文件的实际名称：

```sh
sudo apt install ./ffmpegpp_版本号_amd64.deb
```

可使用 Tab 补全文件名；命令中的“版本号”为占位符，执行前必须替换。

## 1.4 验证处理环境

桌面端应分别验证以下三个部分：

1. **应用界面**能打开。
2. **原生后端**已连接，相关环境检查能够返回。
3. **FFmpeg 与 ffprobe**均可用。

桌面端缺少 FFmpeg 时，可以使用应用的安装助手，或按界面提供的压缩包导入方式准备环境。安装助手依系统调用 winget、常见 Linux 包管理器或 Homebrew；过程中需要网络，也可能需要系统授权。

Android 的 FFmpeg、ffprobe 和原生后端随 APK 打包，通常无需单独安装可执行文件。

::: warning 同时验证 ffprobe
ffprobe 用于读取时长、分辨率与媒体流等信息。即使 ffmpeg 可用，缺少 ffprobe 仍可能导致媒体探测及依赖时长的功能失败。
:::

可在桌面终端中执行以下辅助检查：

```sh
ffmpeg -version
ffprobe -version
```

上述结果仅表示**当前终端的 PATH** 能找到这些程序。应用的启动环境可能不同，因此仍须核对应用内的检查结果。

## 首次启动检查

1. 在设置中确认界面语言。
2. 检查后端、FFmpeg 与 ffprobe 的状态。
3. 选择具有写入权限的输出目录。
4. 导入一份十几秒的素材副本，验证简单处理任务。

Android 端应按系统提示授予文件选取、通知等所需权限。首次验证建议使用单个小文件，避免批量导入增加故障定位的复杂度。

## 常见异常与检查方向

- 界面提示后端未连接：检查安装包完整性，源码构建用户看[构建排障](../build/troubleshooting.md)。
- 媒体导入后无时长、探测失败：先检查 ffprobe 和文件访问权限。
- 节点图无法保存或入队：参阅[图校验](../nodes/preview-validation.md)，分别排查图结构与运行环境。

完成上述检查后，可参阅[界面导览](./interface.md)。
