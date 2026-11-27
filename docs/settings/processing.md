# 3.11 处理设置：工具、目录、并发与通知

首次使用时，确认 FFmpeg 可用且输出目录可写。批量处理时，根据设备资源逐步调整任务并发数；稳定完成任务优先于提高并发数。

## FFmpeg 与 FFprobe

桌面版的“设置”→“处理”→“FFmpeg”显示检测状态、路径和版本，并提供重新检测操作。未检测到 FFmpeg 时，可选择自动安装或手动指定程序。

| 平台/方式 | 前提与行为 |
| --- | --- |
| Windows Winget | 使用系统包管理器安装；需要系统有可用 Winget |
| Linux 包管理器 | 支持识别 apt/dnf/pacman，可能请求管理员认证 |
| macOS Homebrew | 需要先有 Homebrew |
| 手动下载导入 | 按安装对话框选择 FFmpeg 与 FFprobe 压缩包，再导入验证 |
| 手动选择程序 | 选择可执行 FFmpeg；还需相应 FFprobe 才能完整探测 |
| Android | 使用应用内置工具，不显示桌面安装/路径设置组 |

安装后重新检测。检测仍失败时，核对版本和路径并查看日志；重复安装不能替代这些检查。界面中的“删除”仅针对应用识别的内置安装，不会要求删除系统中的所有 FFmpeg。

> **编码器列表不等于硬件保证。** 某项硬编需要 FFmpeg 编译支持、正确驱动及设备能力。Android 当前提供 H.264/HEVC MediaCodec，不能沿用“Android 一律不支持 GPU”的旧说法；具体见[平台差异](platforms.md)。

## 输出与中间目录

- **默认输出目录**：给常规任务提供输出位置。具体流程的输出节点/命令可能有自己的目标，入队后应核对任务显示的实际输出。
- **中间目录**：多步骤中间文件的位置，留空使用系统临时目录。

优先选本机可写、有足够空间的目录。多步处理除了成品，还可能产生中间文件；不能只按最终文件大小估算剩余空间。Android 当前目录选择仍需真实文件系统路径，不能直接把任意 SAF 目录 URI 当作 FFmpeg 输出路径。

## 任务并发与解析线程

| 选项 | 控制阶段 | 当前界面范围 |
| --- | --- | --- |
| 同时启用任务数 | 真正处理队列任务 | 手动 1–8；自动：移动端最多 2、桌面最多 4 |
| 解析线程数 | 添加文件时并行探测媒体 | 1–8 |

若批量添加耗时而转码正常，应检查解析阶段；若转码期间内存紧张或磁盘繁忙，应减少任务并发数。解析线程数不等于单个编码器的线程数；并发任务也不表示同时处理同一文件的多个节点。

## 完成通知与进度通知

1. 开启“任务完成系统通知”。
2. Android 看通知健康状态，按需要申请权限或进入系统通知设置。
3. 用“发送测试通知”检查当前选路。
4. 支持的设备再配置流体云或超级岛进度。

测试结果仅表示应用已尝试调用相应通知路径。通知仍可能受到权限、应用白名单或后台策略限制；“已调用”不表示通知一定会显示。

- ColorOS 流体云入口要求 ROM/provider 可用；当前构建还必须配置正式接入标识，否则可见但禁用。
- 小米超级岛要求支持设备、焦点通知协议版本至少 3，以及焦点通知权限。
- 不支持的 ROM 可能不显示特色入口；任务处理能力与这些通知入口不是同一回事。

更多限制见[平台附录](platforms.md)，任务操作见[队列](../features/queue.md)。

### 实现依据

- [FFmpeg 设置门控与输出目录](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/settings_page.dart#L863-L930)
- [安装方式](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/install_dialog.dart#L239-L275)
- [目录及中间目录](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/settings_page.dart#L4969-L5003)
- [并发、解析与通知](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/settings_page.dart#L5158-L5313)
- [流体云与超级岛条件](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/settings_page.dart#L5392-L5433)
- [超级岛协议及权限](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/settings_page.dart#L5655-L5698)
