# 6.2 快捷键与作用范围

下表列出源码中的默认绑定。已有配置可能保留用户修改过的绑定，实际值以设置页为准。默认表使用 Control；在 macOS 上，不能假定所有 Ctrl 绑定均自动替换为 Command。

## 修改方法

1. 在桌面端进入设置 → 编辑器 → 快捷键。
2. 点击目标条目或其编辑按钮，按下所需组合键。
3. 核对捕获结果与冲突提示后确认。
4. 清空不再需要的绑定后，条目显示“未设置”。

每个组合最多录入 5 个按键，绑定冲突按操作上下文分组检查。项目全选与画布全选均可绑定 Ctrl+A，因为两者作用于不同页面；同一上下文中的重复绑定可能产生冲突。

## 主窗口与项目页

| 默认组合 | 动作 | 作用范围 |
| --- | --- | --- |
| Ctrl+1 | 跳转项目页 | 主窗口导航 |
| Ctrl+2 | 跳转队列页 | 主窗口导航 |
| Ctrl+4 | 跳转设置页 | 主窗口导航 |
| Ctrl+A | 全选项目文件 | 项目页 |
| Ctrl+F | 打开项目搜索 | 项目页 |
| Ctrl+Shift+A | 把已解析文件全部加入队列 | 项目页；不等同于运行容器合并 |
| Ctrl+Shift+Delete | 删除所有项目 | 项目页，会先确认 |
| Ctrl+Shift+S | 开始等待任务 | 队列页 |
| Ctrl+Shift+X | 停止所有任务 | 队列页，有任务处理时 |

> **执行应用快捷操作前，应先移出文本输入焦点。** 搜索框、命名框等处于文本编辑状态时，主窗口优先将按键交给文本编辑；此时 Ctrl+A 用于选择文本。

## 节点画布

| 默认组合/鼠标 | 动作 |
| --- | --- |
| Ctrl+A | 选中所有画布元素 |
| Delete | 删除选中元素 |
| Ctrl+Z | 撤销 |
| Ctrl+Shift+Z | 重做 |
| 鼠标右键 | 默认平移按钮 |
| 鼠标左键 | 默认框选按钮 |
| 未设置 | 探测模式快捷键，需自行配置 |
| 未设置 | 隐藏逻辑部分快捷键，需自行配置 |

鼠标平移与选择按钮可在快捷键设置中调整。画布焦点、弹窗与输入框均会影响按键分发。快捷键未生效时，应点击画布空白处，并核对绑定及冲突提示后重试。

探测模式的用法及其与实际执行的区别见[预览与校验](/nodes/preview-validation)。移动端主要通过触摸与页面按钮操作，具体入口以对应平台说明为准。

## 操作注意事项

首次使用时，可先熟悉 Ctrl+F、Ctrl+Z 与导航快捷键。执行批量入队、清空或停止操作前，应确认当前上下文，并区分项目页“全部文件入队”与容器批处理规则。

### 实现依据

- [完整默认键表](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/models/models.dart#L2752-L2770)
- [绑定编辑、清空与冲突提示](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/keybinding_page.dart#L80-L161)
- [录入上限与确认](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/keybinding_page.dart#L618-L717)
- [输入框保护及项目/队列作用域](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/app.dart#L853-L976)
