# 1.3 下载与首次启动

第一次用，先把软件和处理环境准备好。这一步顺了，后面排查问题会轻松很多。

## 选对安装包

打开[项目 Releases](https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases)，展开对应版本的 Assets。文件名里的版本号会变化，重点看平台和架构。

| 系统 | 选择方向 | 说明 |
| --- | --- | --- |
| Windows x64 | `FFmpeg++_v*_setup.exe` | 使用安装向导 |
| Linux x64 | `*_amd64.deb` | amd64 就是通常所说的 x86_64 |
| Linux ARM64 | `*_arm64.deb` | 不要和 amd64 混用 |
| macOS | `*_macOS.dmg` | 仓库发布流程构建 Universal 包 |
| Android | `app-release.apk` | 当前只打包 arm64-v8a，最低 Android 8.0 |

这里列的是仓库的发布目标；某个 Release 是否包含全部附件，要看该次实际上传的文件。

### Linux 安装示例

在下载目录中，用真实文件名替换下面的包名：

```sh
sudo apt install ./ffmpegpp_版本号_amd64.deb
```

选文件时可以按 Tab 补全。别把“版本号”三个字原样留在命令里。

## 1.4 处理环境要检查什么？

桌面端主要检查三层：

1. **应用界面**能打开。
2. **原生后端**已连接，相关环境检查能够返回。
3. **FFmpeg 与 ffprobe**均可用。

桌面端缺少 FFmpeg 时，可以使用应用的安装助手，或按界面提供的压缩包导入方式准备环境。安装助手依系统调用 winget、常见 Linux 包管理器或 Homebrew；过程中需要网络，也可能需要系统授权。

Android 的 FFmpeg、ffprobe 和后端随 APK 打包，通常不需要另装桌面版可执行文件。

::: warning 别只检查 ffmpeg
ffprobe 用来读取时长、分辨率、流信息等。只有 ffmpeg、没有 ffprobe，媒体探测和依赖时长的功能仍可能出问题。
:::

桌面终端也可以辅助检查：

```sh
ffmpeg -version
ffprobe -version
```

这只能说明**这个终端的 PATH**里能找到它们。应用启动环境可能不同，仍要看应用内的检查结果。

## 首次打开，建议先做这四件事

1. 在设置里确认界面语言。
2. 检查后端、FFmpeg 和 ffprobe 状态。
3. 选一个有写入权限的输出目录。
4. 导入一份十几秒的素材副本，先跑通简单任务。

手机上要按系统提示授予选取文件、通知等所需权限。不要一次导入大量素材来“测试安装成功没有”，一个小文件就够了。

## 如果没有顺利启动

- 界面提示后端未连接：检查安装包完整性，源码构建用户看[构建排障](../build/troubleshooting.md)。
- 媒体导入后无时长、探测失败：先检查 ffprobe 和文件访问权限。
- 有图却不能保存或入队：看[图校验](../nodes/preview-validation.md)，它和安装环境是两回事。

准备好后，去看[界面导览](./interface.md)。
