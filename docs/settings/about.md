# 3.13 关于、版本与更新

报告问题时，可在“设置”→“关于”中确认软件版本和编译日期。版本表示发布标识，编译日期用于区分不同构建。

## 检查更新

桌面“版本与更新”里有手动检查按钮，也可开“启动时自动检查更新”。自动检查是静默检查，通常只在有新版本时提示。

移动端点更新行在线检查，长按可直达发布页。更新对话框显示新旧版本、发布说明，来源提供时也会显示提取密码。发布说明获取失败不代表没有新版本，版本与说明可能来自不同网络来源。

## 按平台区分下载与安装流程

| 情况 | 界面行为 |
| --- | --- |
| 桌面、GitHub 来源、有匹配资产 | 可提供下载安装 |
| 移动端 | 打开浏览器下载链接或发布页，由系统/用户继续安装 |
| 其他来源或没有匹配包 | 前往下载，不走桌面自动安装 |
| Windows 自动安装 | 启动下载的安装程序并退出当前应用 |
| macOS 自动安装 | 打开 DMG 并退出，仍需按系统流程完成安装 |
| Linux 自动安装 | 走 pkexec + dpkg 安装路径，不是所有发行版通用的包管理入口 |

> **更新前保存配置并等待正在运行的任务结束。** 下载安装流程中的“下载完成”“安装程序已启动”和“新版本已成功运行”是不同状态，不能相互替代。

应用会尝试使用发布资产提供的 SHA-256 摘要校验下载。若发布方未提供摘要，应用仅检查文件非空及扩展名、平台匹配等条件，并显示警告；此时未完成密码学完整性校验。

中文界面下，更新检查优先使用蓝奏来源并获取 GitHub 发布说明，失败后再回退；其他语言优先尝试 GitHub。因此，不同语言下使用的网络来源和自动安装条件可能不同。手动下载时应核对操作系统和架构；同属 Linux 的软件包不一定兼容。

## 关于页中的其他入口

关于页提供项目和博客链接、赞助及引用信息。移动端还提供广告页面入口；该页面可能没有投放内容，显示入口不表示每次访问都会展示广告。

提交问题报告时，请同时提供版本、系统信息和[日志](../features/logs.md)。平台安装与通知差异见[平台附录](platforms.md)。

### 实现依据

- [关于页及更新入口](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/settings_page.dart#L6122-L6376)
- [自动安装门控](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/settings_page.dart#L7149-L7260)
- [更新源优先级](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/update_service.dart#L178-L209)
- [缺少摘要时的降级检查](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/update_service.dart#L519-L528)
- [实际安装和退出方式](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/update_service.dart#L594-L616)
