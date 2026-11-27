---
layout: home
hero:
  name: FFmpeg++
  text: 可视化媒体处理工作流
  tagline: 涵盖媒体导入、节点配置、任务执行、源码构建与流程文件编写的使用手册。
  actions:
    - theme: brand
      text: 创建第一个任务
      link: /guide/first-task
    - theme: alt
      text: 编写节点文件
      link: /node-files/
features:
  - title: 操作流程
    details: 说明安装、导入、连线、保存与任务入队的操作入口和检查方法。
    link: /guide/installation
  - title: 参数参考
    details: 说明节点参数的含义、单位、适用条件与平台限制。
    link: /nodes/
  - title: 流程文件编写
    details: 介绍 JSON 节点图的字段结构，以及可导入 .fppx 文件的封装方法。
    link: /node-files/first-file
---

## 按使用目标查阅

| 使用目标 | 参考章节 |
| --- | --- |
| 完成安装并验证首次运行 | [安装与首次启动](./guide/installation.md) → [第一个任务](./guide/first-task.md) |
| 创建节点处理流程 | [节点编辑器](./nodes/index.md) → [创建节点](./nodes/creation.md) |
| 配置串行处理参数 | [快捷配置](./features/quick-config.md) |
| 查询设置项的作用 | [外观](./settings/appearance.md)、[处理](./settings/processing.md)、[高级](./settings/advanced.md) |
| 通过文本编写流程文件 | [编写节点编辑器文件](./node-files/index.md) |
| 从源码构建应用 | [构建前准备](./build/index.md) |
| 部署文档站点 | [GitHub Pages 部署](./deployment/github-pages.md) |

::: info 适用版本
本手册对应 **6.0.0-beta2** 的仓库实现，核对基线为 `244623d`。菜单名称以中文界面为准；桌面端与 Android 的差异在相关章节中分别说明。建议先使用媒体副本或短素材验证示例，再扩大处理范围。
:::

## 阅读方式

首次使用时，建议按章节顺序阅读；查询具体问题时，可使用页面右上角的搜索功能。操作步骤采用编号列表，参数说明采用表格，注意事项以提示框标注。

“导入成功”“图校验通过”与“任务执行成功”分别表示不同阶段的结果。任一阶段通过，均不能保证其余阶段成功。
