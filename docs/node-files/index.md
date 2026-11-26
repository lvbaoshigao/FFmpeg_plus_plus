# 5.1 编写节点编辑器文件：先分清“图”和“文件”

想用文本批量生成流程，或者给一组文件统一改参数？这一章就是干这个的。我们从一张很小的图开始，最后做出能让 FFmpeg++ 导入的 `.fppx` 文件。

## 先对齐目标

这里的“编写节点编辑器文件”，指的是**编写已有节点组成的流程配置**，不是给软件开发一种全新的节点插件。你可以改节点、参数、坐标和连线；软件不认识的新处理类型，不能只靠在 JSON 里写个名字就生效。

## 要经过哪几层？

```text
可编辑的图 JSON
    ↓ 检查字段、ID 与连线
旧版 .fppx 二进制封装
    ↓ 在配置库或编辑器导入
界面图校验 → 应用到媒体 → 入队执行
    ↓ 可选
由应用重新导出为新版 (Beta) .fppx
```

| 名字 | 本质 | 能否直接在文本编辑器中改？ |
| --- | --- | --- |
| 图 JSON | `nodes`、`connections`、`logicBlocks` 等对象 | 可以，适合手写和版本管理 |
| 旧版 .fppx | 文件头、描述、长度字段，加上 gzip 压缩的图 JSON | 要先解包，改好再封装 |
| 新版 .fppx | 模块、类型 ID、索引、校验；还可能加密 | 交给应用读写，本章说明结构与边界 |

::: warning 改后缀不等于转换格式
把 `flow.json` 重命名为 `flow.fppx`，内容还是 JSON，导入时会因为文件头不对而失败。必须经过封装。
:::

## 本章提供什么？

- [视频截取 JSON](/examples/clip-video.json)与[已封装配置](/examples/clip-video.fppx)。
- [音频波形图 JSON](/examples/audio-waveform.json)与[已封装配置](/examples/audio-waveform.fppx)。
- [控制连线与分组 JSON](/examples/controlled-clip.json)与[已封装配置](/examples/controlled-clip.fppx)。
- 一个只用 Python 标准库的[检查、打包和解包工具](/examples/fppx_tool.py)。
- 可供编辑器提示字段的[JSON Schema](/schemas/pipeline-graph.schema.json)。

工具需要 **Python 3.9 或更高版本**，只处理旧版 1.2 节点配置，不实现新版格式、快速模式或 AES。它检查结构和少数关键参数，不能替代应用的完整校验。

## 建议的阅读顺序

1. [写出第一张节点图](./first-file.md)：先照着改一个能看懂的小例子。
2. [字段与参数](./schema.md)：想知道某个键能不能省、该写什么类型时查这里。
3. [逻辑与控制连线](./logic.md)：有了串行链基础，再加逻辑。
4. [封装、导入与调试](./pack-import.md)：真正把 JSON 用起来。
5. [新版格式与兼容性](./formats.md)：理解为什么同样叫 .fppx，内容却不一样。
