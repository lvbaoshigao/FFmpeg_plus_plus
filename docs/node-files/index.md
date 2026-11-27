# 5.1 节点图与文件格式：编写节点编辑器文件

通过文本可批量生成流程或统一修改多份文件的参数。本章从简单图结构开始，说明如何生成可由 FFmpeg++ 导入的 `.fppx` 文件。

## 范围与目标

“编写节点编辑器文件”在此指**编写由现有节点组成的流程配置**，而非开发新的节点插件。可在配置中修改节点、参数、坐标和连线；JSON 中填写软件不支持的处理类型名称，不会使该类型生效。

## 文件处理流程

```text
可编辑的图 JSON
    ↓ 检查字段、ID 与连线
旧版 .fppx 二进制封装
    ↓ 在配置库或编辑器导入
界面图校验 → 应用到媒体 → 入队执行
    ↓ 可选
由应用重新导出为新版 (Beta) .fppx
```

| 名字 | 本质 | 文本编辑器可编辑性 |
| --- | --- | --- |
| 图 JSON | `nodes`、`connections`、`logicBlocks` 等对象 | 可以，适合手写和版本管理 |
| 旧版 .fppx | 文件头、描述、长度字段，加上 gzip 压缩的图 JSON | 要先解包，改好再封装 |
| 新版 .fppx | 模块、类型 ID、索引、校验；还可能加密 | 交给应用读写，本章说明结构与边界 |

::: warning 改后缀不等于转换格式
把 `flow.json` 重命名为 `flow.fppx`，内容还是 JSON，导入时会因为文件头不对而失败。必须经过封装。
:::

## 材料与工具

- [视频截取 JSON](/examples/clip-video.json)与[已封装配置](/examples/clip-video.fppx)。
- [音频波形图 JSON](/examples/audio-waveform.json)与[已封装配置](/examples/audio-waveform.fppx)。
- [控制连线与分组 JSON](/examples/controlled-clip.json)与[已封装配置](/examples/controlled-clip.fppx)。
- 一个只用 Python 标准库的[检查、打包和解包工具](/examples/fppx_tool.py)。
- 可供编辑器提示字段的[JSON Schema](/schemas/pipeline-graph.schema.json)。

工具需要 **Python 3.9 或更高版本**，仅处理旧版 1.2 节点配置，不支持新版格式、快速模式或 AES。工具会检查结构和部分关键参数，但不能替代应用的完整校验。

## 阅读顺序

1. [写出第一张节点图](./first-file.md)：通过简单示例熟悉配置结构。
2. [字段与参数](./schema.md)：查询字段是否可省略及其数据类型。
3. [逻辑与控制连线](./logic.md)：了解如何在串行处理链基础上配置逻辑。
4. [封装、导入与调试](./pack-import.md)：真正把 JSON 用起来。
5. [新版格式与兼容性](./formats.md)：理解为什么同样叫 .fppx，内容却不一样。
