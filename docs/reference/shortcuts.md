# 6.2 快捷键：先看作用范围，再记组合键

下面是当前源码中的默认值；已有配置可能保留你之前改过的绑定，以设置页显示为准。默认表使用 Control，不能直接假定 macOS 已把全部 Ctrl 自动替换为 Command。

## 修改方法

1. 桌面进入设置 → 编辑器 → 快捷键。
2. 点某项或它的编辑按钮，按下要使用的组合键。
3. 核对捕获结果和冲突提示，再确认。
4. 不需要的绑定可清空，显示“未设置”。

录入最多 5 个按键，冲突按上下文分组检查。项目全选与画布全选同为 Ctrl+A，因页面不同可以共存；在同一上下文重复绑定才容易互相抢占。

## 主窗口与项目页

| 默认组合 | 动作 | 作用范围 |
| --- | --- | --- |
| Ctrl+1 | 跳转项目页 | 主窗口导航 |
| Ctrl+2 | 跳转队列页 | 主窗口导航 |
| Ctrl+3 | 跳转命令页 | 桌面主窗口导航 |
| Ctrl+4 | 跳转设置页 | 主窗口导航 |
| Ctrl+A | 全选项目文件 | 项目页 |
| Ctrl+F | 打开项目搜索 | 项目页 |
| Ctrl+Shift+A | 把已解析文件全部加入队列 | 项目页；不等同于运行容器合并 |
| Ctrl+Shift+Delete | 删除所有项目 | 项目页，会先确认 |
| Ctrl+Shift+S | 开始等待任务 | 队列页 |
| Ctrl+Shift+X | 停止所有任务 | 队列页，有任务处理时 |

> **先点出输入框再试应用动作。** 搜索框、命名框等正在编辑文字时，主窗口会把按键交给文本编辑；此时 Ctrl+A 应选中文字，不应误清项目。

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

鼠标平移/选择按钮可在快捷键设置中调整。画布焦点、弹窗、输入框会影响按键去向；“没触发”时先点画布空白处，核对绑定和冲突，再尝试。

探测模式如何用、与真实执行的区别，见[预览与校验](/nodes/preview-validation)。移动端以触摸和页面按钮为主，不应把桌面快捷键列表当作移动端入口清单。

## 一个小习惯

第一次只记 Ctrl+F、Ctrl+Z 和两个导航键就够了。批量入队、清空、停止等影响更大的组合，确认上下文后再用，避免把项目页“全部文件入队”与容器自己的批处理规则混淆。

### 实现依据

- [完整默认键表](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/models/models.dart#L2752-L2770)
- [绑定编辑、清空与冲突提示](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/keybinding_page.dart#L80-L161)
- [录入上限与确认](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/keybinding_page.dart#L618-L717)
- [输入框保护及项目/队列作用域](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/app.dart#L853-L976)
