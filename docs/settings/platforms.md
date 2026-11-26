# 6.4 平台差异与能力边界

同一个设置在某台设备上看不到，可能只是平台能力不同。先用这张表定位，再去相关教程操作。这里区分“代码有移动布局分支”和“完整平台能力已验证”，不会因为判断里包含 iOS 就承诺所有 Android 原生服务也可用。

## 入口和系统服务

| 功能 | 桌面 | Android / 移动布局 |
| --- | --- | --- |
| 主页面导航 | 侧栏含命令等入口 | 命令、日志放在设置 → 工具 |
| 编辑模式、自动保存 | 设置 → 编辑器 | 设置 → 外观 → 节点编辑器 |
| FFmpeg 安装/路径 | 检测、安装、手动选择 | Android 工具随应用提供，移动布局隐藏安装组 |
| 文件拖放 | 项目页提供 | 移动端不挂桌面拖放入口 |
| 字体 | 系统字体列表及导入 | 系统默认或导入，不列整份系统字体 |
| 多窗口面板 | 桌面有独立面板服务 | 不等同于移动端应用分屏 |
| 命令运行 | 识别输入/输出后入队 | 直接运行 ffmpeg/ffprobe 并显示结果 |
| 高刷新率 | 没有 Android 原生调用效果 | 实际实现仅 Android |
| 预测式返回 | 不适用 | 仅 Android 实现 |
| 更新 | 满足条件可下载并启动安装 | 浏览器下载，由用户/系统继续 |

## 编码器要分“可选”和“能用”

| 平台/选项 | 当前编码节点提供什么 |
| --- | --- |
| 桌面 CPU | x264/x265、VP9/AV1 等软件编码与复制流选项 |
| 桌面 NVIDIA / AMD / Intel | NVENC / AMF / QSV 对应编码器 |
| Android | CPU 与 Android；Android 对应 H.264、HEVC MediaCodec |
| iOS 移动分支 | 编码节点限制为 CPU；不能据此承诺完整 iOS 发布/处理链 |

**Android 不是“GPU 硬编不可用”。** 当前已有 MediaCodec 选项。反过来，下拉菜单有编码器也不能证明设备和当前 FFmpeg 能运行。失败时检查日志中的不支持编码器、驱动、分辨率或像素格式错误。

旧式快捷项转图在 Android 会把 HEVC 映射为 HEVC MediaCodec，其余某些编码选择映射为 H.264 MediaCodec；尤其不要把旧 AV1/VP9 选项理解成设备一定在输出 AV1/VP9。当前新向导应以节点实际参数与最终命令为准。

## 文件与目录

普通媒体导入遇到 SAF/文档选择器的无本地路径来源，会流式复制到临时文件，可能额外占磁盘空间。容器部分文件选择入口只接收本地路径，体验不一定与普通添加完全相同。

当前输出目录选择保留真实路径接口，不能直接把任意 SAF 目录 URI 当作 FFmpeg 可写目录。Android 打开结果通过系统文件服务；私有目录可能无法被文件管理器直接浏览，此时会尝试直接打开文件。

## 通知

- 普通任务完成通知仍受系统通知权限、总开关和后台策略影响。
- ColorOS 流体云需要 ROM/provider 可用，并且此构建已配置正式接入标识。
- 小米超级岛需要支持设备、协议至少 3、焦点通知权限。
- 测试通知返回只表明尝试选路，不保证通知实际出现在屏幕上。

不支持设备不显示特色入口，并不影响普通转码。不要为了找一个本机没有的开关反复重装。

## 并发、暂停与恢复

自动任务并发上限移动端 2、桌面 4，手动可选至 8。暂停是当前运行的进程控制；无可冻结进程时失败，Windows 本地进程路径也有限制。历史任务恢复不等于编码进度续传。

### 实现依据

- [平台判定](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/platform/app_platform.dart#L9-L25)
- [设置分组的门控](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/settings_page.dart#L863-L1112)
- [编码器与 iOS 分支](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/av_process_step_editor.dart#L21-L83)
- [GPU 选项的平台菜单](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/av_process_step_editor.dart#L205-L225)
- [旧快捷项 Android 映射](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/quick_config_pipeline.dart#L133-L156)
- [目录真实路径边界](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/directory_picker.dart#L3-L11)
- [通知能力条件](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/progress_feature_availability.dart#L3-L15)
- [本地进程暂停限制](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/task_process_runner.dart#L71-L89)
