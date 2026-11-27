# 6.4 平台差异与能力边界

某项设置未在设备上显示时，可能是平台支持范围不同。可先依据下表确认平台差异，再查看对应教程。本文区分“代码包含移动端布局分支”与“平台能力已完整验证”；代码路径涉及 iOS 不表示 Android 原生服务在所有移动平台均可用。

## 入口和系统服务

| 功能 | 桌面 | Android / 移动布局 |
| --- | --- | --- |
| 主页面导航 | 侧栏切换项目、队列、配置库、设置和日志 | 底部导航切换项目、队列、配置库和设置；日志放在设置 → 工具 |
| 编辑模式、自动保存 | 设置 → 编辑器 | 设置 → 外观 → 节点编辑器 |
| FFmpeg 安装/路径 | 检测、安装、手动选择 | Android 工具随应用提供，移动布局隐藏安装组 |
| 文件拖放 | 项目页提供 | 移动端不挂桌面拖放入口 |
| 字体 | 系统字体列表及导入 | 系统默认或导入，不列整份系统字体 |
| 多窗口面板 | 桌面有独立面板服务 | 不等同于移动端应用分屏 |
| 高刷新率 | 没有 Android 原生调用效果 | 实际实现仅 Android |
| 预测式返回 | 不适用 | 仅 Android 实现 |
| 更新 | 满足条件可下载并启动安装 | 浏览器下载，由用户/系统继续 |

## 编码器选项与实际可用性

| 平台/选项 | 当前编码节点提供什么 |
| --- | --- |
| 桌面 CPU | x264/x265、VP9/AV1 等软件编码与复制流选项 |
| 桌面 NVIDIA / AMD / Intel | NVENC / AMF / QSV 对应编码器 |
| Android | CPU 与 Android；Android 对应 H.264、HEVC MediaCodec |
| iOS 移动分支 | 编码节点限制为 CPU；不能据此承诺完整 iOS 发布/处理链 |

**Android 提供 MediaCodec 硬件编码选项。** 但菜单中列出编码器不代表当前设备和 FFmpeg 均可运行该编码器。处理失败时，请检查日志中的编码器支持、驱动、分辨率或像素格式错误。

旧式快捷项转换为节点图时，Android 会将 HEVC 映射为 HEVC MediaCodec，其他部分编码选项会映射为 H.264 MediaCodec。因此，旧 AV1/VP9 选项不表示设备实际输出 AV1/VP9。使用当前向导时，应以节点参数和最终命令为准。

## 文件与目录

通过 SAF 或文档选择器导入没有本地路径的普通媒体来源时，应用会将其流式复制到临时文件，因而可能占用额外磁盘空间。容器中的部分文件选择入口仅接受本地路径，处理方式与普通文件添加不同。

输出目录选择使用真实文件系统路径；任意 SAF 目录 URI 不能直接作为 FFmpeg 输出目录。Android 通过系统文件服务打开结果。文件管理器无法浏览私有目录时，应用会尝试直接打开输出文件。

## 通知

- 普通任务完成通知仍受系统通知权限、总开关和后台策略影响。
- ColorOS 流体云需要 ROM/provider 可用，并且此构建已配置正式接入标识。
- 小米超级岛需要支持设备、协议至少 3、焦点通知权限。
- 测试通知返回只表明尝试选路，不保证通知实际出现在屏幕上。

不支持相关功能的设备不会显示特色入口，但普通转码不受此影响。重装应用不会使设备获得原本不支持的功能或设置项。

## 并发、暂停与恢复

自动任务并发上限为移动端 2、桌面 4；手动上限为 8。暂停仅控制当前运行进程：没有可冻结的进程时，暂停操作会失败；Windows 本地进程路径存在额外限制。应用可恢复历史任务记录，但不会从上次中断的编码进度继续。

### 实现依据

- [平台判定](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/platform/app_platform.dart#L9-L25)
- [设置分组的门控](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/settings_page.dart#L863-L1112)
- [编码器与 iOS 分支](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/av_process_step_editor.dart#L21-L83)
- [GPU 选项的平台菜单](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/av_process_step_editor.dart#L205-L225)
- [旧快捷项 Android 映射](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/quick_config_pipeline.dart#L133-L156)
- [目录真实路径边界](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/directory_picker.dart#L3-L11)
- [通知能力条件](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/progress_feature_availability.dart#L3-L15)
- [本地进程暂停限制](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/task_process_runner.dart#L71-L89)
