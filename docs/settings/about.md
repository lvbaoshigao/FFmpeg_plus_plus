# 3.13 关于、版本与更新

要报告问题，先到设置 → 关于，确认软件版本与编译日期。它们不是同一个信息：版本表示发布标识，编译日期帮助区分构建。

## 检查更新

桌面“版本与更新”里有手动检查按钮，也可开“启动时自动检查更新”。自动检查是静默检查，通常只在有新版本时提示。

移动端点更新行在线检查，长按可直达发布页。更新对话框显示新旧版本、发布说明，来源提供时也会显示提取密码。发布说明获取失败不代表没有新版本，版本与说明可能来自不同网络来源。

## 下载与安装不是所有平台都一样

| 情况 | 界面行为 |
| --- | --- |
| 桌面、GitHub 来源、有匹配资产 | 可提供下载安装 |
| 移动端 | 打开浏览器下载链接或发布页，由系统/用户继续安装 |
| 其他来源或没有匹配包 | 前往下载，不走桌面自动安装 |
| Windows 自动安装 | 启动下载的安装程序并退出当前应用 |
| macOS 自动安装 | 打开 DMG 并退出，仍需按系统流程完成安装 |
| Linux 自动安装 | 走 pkexec + dpkg 安装路径，不是所有发行版通用的包管理入口 |

> **先保存，再更新。** 特别是打开着画布或正在处理任务时，先保存配置并等任务结束。不要把“下载完成”“安装程序已启动”和“新版本已成功运行”当成同一个状态。

应用会尝试用发布资产的 SHA-256 校验下载。发布方未提供摘要时，仅做非空、扩展名/平台匹配等基础检查，并给出警告；不能把这种下载描述成完成了密码学完整性校验。

中文界面检查优先尝试蓝奏来源并取 GitHub 发布说明，失败再回退；其他语言先尝试 GitHub。网络来源与自动安装条件可能因此不同。手动下载时核对操作系统与架构，不要只看“都是 Linux”就混用包。

## 其他关于入口

可以查看项目/博客链接、赞助与引用。移动端还提供广告页面入口，页面当前可能显示无投放内容；出现入口不等于每次都有广告。

需要排查时，把版本和系统信息与[日志](../features/logs.md)一起提供。平台安装和通知差异见[平台附录](platforms.md)。

### 实现依据

- [关于页及更新入口](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/settings_page.dart#L6122-L6376)
- [自动安装门控](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/settings_page.dart#L7149-L7260)
- [更新源优先级](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/update_service.dart#L178-L209)
- [缺少摘要时的降级检查](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/update_service.dart#L519-L528)
- [实际安装和退出方式](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/update_service.dart#L594-L616)
