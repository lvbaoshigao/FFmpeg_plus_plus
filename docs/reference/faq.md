# 6.1 常见问题：先看卡在哪一步

不用先把设置全部重置。先判断卡在导入、配置、入队、执行还是找结果，再查对应一项。

~~~text
文件加不进来 → 检查来源、扩展名与本地可读路径
已添加但解析失败 → 检查 FFprobe 与媒体内容
配置不能保存/应用 → 检查类型、连线和节点参数
入队却没运行 → 到队列开始，检查状态与并发
运行失败 → 看任务错误、命令与日志
运行完成找不到 → 看任务实际输出路径，再用打开文件/定位
~~~

## 导入与配置

### 文件已经在列表里，为什么还不能处理？

添加与解析是两个阶段。先等解析结束；失败时看 FFprobe 错误。增加“解析线程数”只改变并行导入探测，不会修好损坏媒体或不可读路径。[媒体导入](../features/project.md)

### 文件夹里的子目录为什么没导入？

“从文件夹创建容器”只扫描所选目录这一层，按扩展名收普通媒体文件，不递归扫描子目录。可以分批建容器或手动选文件。[容器操作](../features/project.md)

### 为什么快捷配置里找不到某节点？

候选跟随当前链尾媒体类型；快捷链本身不支持逻辑门、分支和多文件合并。先看上游输出类型，需要复杂结构时转节点编辑器。[快捷配置](../features/quick-config.md)

### 想打开快速模式，为什么仍提示节点编辑器？

已有图含分支、逻辑、孤立或无法串行化结构时，不会被静默裁成一条链。继续在节点编辑器编辑，或为另一个文件建立明确的串行流程。

### 应用配置库时，模板为什么不在列表？

只显示兼容且能校验的配置。检查媒体类型、源节点声明与参数。应用到某个文件使用流程副本，不会直接修改模板。[配置库](../features/library.md)

### 给容器内文件套了配置，为什么批量跑没用？

“应用到文件”改的是独立流程，容器运行仍用容器共用流程。要批量改变，请编辑容器本身；只处理该文件则使用文件独立入口。

## 执行与结果

### 入队是不是就开始了？

不是。去队列点“开始处理”，或开始某个等待任务。暂停状态还占并发槽位，需要继续或停止。[队列](../features/queue.md)

### 暂停按不了，或提示当前无法暂停？

当前可能正处在步骤切换、没有可冻结进程的阶段；Windows 本地进程路径也有冻结信号限制。应用不会只改状态假装成功。重启后暂停任务会重置等待，不是断点续传。

### “清除已完成”为什么连失败记录也没了？

它清理的是终态：完成、失败、取消都会移出列表。先复制排障证据再清理。记录移除不删除输出成品。[日志](../features/logs.md)

### 自动并发开到最大为什么更慢？

CPU、GPU、内存与磁盘可能互相争用。先降低同时任务数比较。它与导入的解析线程、编码器内部线程不是一个概念。[处理设置](../settings/processing.md)

### Android 能硬编吗？

当前有 H.264/HEVC MediaCodec 选项，并非一律不支持 GPU。是否能用仍取决于设备、FFmpeg 构建及参数；先读具体错误，再检查硬编配置。[平台差异](../settings/platforms.md)

### 命令页提示找不到程序，可项目转码正常？

移动端命令页直接调用所填可执行文件，与常规项目任务的路径处理不同。确认命令程序路径，不要据此判定整个后端失效。桌面命令页则要求本地输入及末尾输出并入队。[命令模式](../features/commands.md)

## AI、通知与空间

### 配好了 Responses API，为什么发不出去？

当前统一 AI SDK 的实际对话入口不支持 Responses API，会提示切换 Chat Completions。还需选好非空模型与 Key。[AI 助手](../features/ai.md)

### 附件加进去了，模型为什么没读到内容？

普通文件主要提供路径等元数据；图片还要求视觉能力标记和大小预算。不保证所有文档、视频、音频都会直接上传解析。看附件类型、模型能力与[附件限制](../features/ai.md)。

### AI 写入开关开了，MCP 还提示权限不足？

两套权限独立。检查 MCP 服务自己的写入与文件系统访问开关；局域网还要新令牌。[MCP 接入](../features/mcp.md)

### 开了通知却没显示，或没有流体云/超级岛开关？

先看系统通知权限与总开关，再看 ROM 能力。流体云还需接入标识，超级岛需要协议与焦点通知权限。测试返回表示尝试选路，不保证系统展示。[通知设置](../settings/processing.md)

### 清缓存后为什么还占空间？

仍被项目或队列引用的导入副本会保留。先处理不再需要的记录，再清普通缓存；“图片/字体”是另一类，会移除自定义资源。[清理范围](../settings/advanced.md)

### 更新点完后为什么还要自己安装？

移动端打开浏览器下载；macOS 打开 DMG；Linux 自动路径使用 dpkg。不是所有平台都在应用内完成无感替换。[更新说明](../settings/about.md)

## 仍解决不了时，准备这几项

- 软件版本、操作系统/设备、FFmpeg 来源。
- 输入类型与可复现的最小步骤。
- 相关节点参数、是否硬编、实际输出路径。
- 任务错误、实际命令、相关全局日志；分享前遮盖路径隐私、Key、令牌。

### 关键实现依据

- [导入探测流程](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/providers/app_state.dart#L1037-L1117)
- [串行快捷链约束](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/quick_config_pipeline.dart#L435-L556)
- [恢复状态修正](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/providers/app_state.dart#L6121-L6149)
- [Android 硬编选项](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/widgets/step_editors/av_process_step_editor.dart#L21-L48)
- [AI 发送守卫](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/pipeline_editor_page.dart#L15298-L15357)
