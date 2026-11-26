---
layout: home
hero:
  name: FFmpeg++
  text: 把处理流程连起来
  tagline: 从第一次导入媒体，到写出自己的节点文件，一步一步来。
  actions:
    - theme: brand
      text: 先做一个任务
      link: /guide/first-task
    - theme: alt
      text: 学会编写节点文件
      link: /node-files/
features:
  - title: 少走一点弯路
    details: 安装、导入、连接、保存、入队，每一步都说清入口和检查方法。
    link: /guide/installation
  - title: 参数也要讲明白
    details: 不只告诉你按钮在哪，还解释参数的意思、单位和平台限制。
    link: /nodes/
  - title: 流程可以自己写
    details: 从 JSON 节点图开始，读懂字段，封装成真正可以导入的 .fppx 文件。
    link: /node-files/first-file
---

## 你现在想做什么？

| 你的目标 | 建议入口 |
| --- | --- |
| 刚装好，不知道从哪里开始 | [安装与首次启动](./guide/installation.md) → [第一个任务](./guide/first-task.md) |
| 已经会导入，想搭一条处理流程 | [节点编辑器](./nodes/index.md) → [创建节点](./nodes/creation.md) |
| 只想快速调几个参数 | [快捷配置](./features/quick-config.md) |
| 找某个设置的作用 | [外观](./settings/appearance.md)、[处理](./settings/processing.md)、[高级](./settings/advanced.md) |
| 想用文本批量制作流程文件 | [编写节点编辑器文件](./node-files/index.md) |
| 想自己编译软件 | [构建前准备](./build/index.md) |
| 想发布这份文档 | [GitHub Pages 部署](./deployment/github-pages.md) |

::: info 先说明版本
这份手册对应仓库当前的 **6.0.0-beta2** 实现，核对基线为 `244623d`。菜单名称以中文界面为主；桌面端和 Android 不同的地方会单独说明。文中的示例先用于副本或短素材，确认结果后再扩大处理范围。
:::

## 怎么读更省力？

第一次使用，可以按章节顺着看；遇到具体问题，直接用右上角搜索。操作步骤会用编号列表，参数用表格，容易踩坑的地方放进提醒框。

“导入成功”“图校验通过”和“任务执行成功”是三个不同阶段。手册会分别说明，不把其中一个当作另外两个的保证。
