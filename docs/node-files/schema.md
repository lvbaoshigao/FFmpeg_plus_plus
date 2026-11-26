# 5.3 字段与参数：哪些地方一定要写对？

JSON 看起来像表格的另一种写法。真正容易出错的，通常是**字段名、值类型和引用关系**，不是缩进。

## 图的最外层

| 字段 | 类型 | 用途 |
| --- | --- | --- |
| `nodes` | 对象数组 | 图中的节点 |
| `connections` | 对象数组 | 图中的连线 |
| `logicBlocks` | 对象数组，可省略 | 分组、循环与条件块 |

根对象直接放这些字段。不要额外包成 `{"graph": {...}}`，也不要把配置库条目的 `name`、`graph` 外壳一起当作图。

应用模型对部分缺失字段有默认值。为了减少手写歧义，教程约定显式填写节点的 `id`、`type`、`params`、`x`、`y`，连线填写 `id`、`from`、`to`。我们提供的 [Schema](/schemas/pipeline-graph.schema.json)采用这套较明确的编写约定，**不是应用执行规则的完整正式规范**。

## 节点字段

| 字段 | 写法 | 必须留意 |
| --- | --- | --- |
| `id` | 非空字符串 | 节点之间不能重复，连线按它引用 |
| `type` | 已知类型的字符串 | 大小写敏感，例如 `audioWaveform` |
| `params` | 对象 | 数字、布尔和字符串不能随意互换 |
| `x` / `y` | 数字 | 缺省为 0，坐标不影响执行顺序 |
| `gate` | 逻辑门名称，可省略 | 有门时用 `type: "start"`，见下一页 |
| `type_id` | 未知节点保留字段 | 用于新版文件往返，不用于定义自制节点 |

不要把 UI 的中文节点名写进 `type`。例如：

| 界面里看到的功能 | 图里的 type |
| --- | --- |
| 源文件 / 输出 | `start` / `output` |
| 音视频处理 / 字幕烧录 | `avProcess` / `subtitle` |
| 片段截取 / 帧提取 / 变速 | `clip` / `frame` / `speed` |
| 音量 / 均衡器 | `audioVolume` / `audioEqualizer` |
| 频谱图 / 波形图 | `audioSpectrum` / `audioWaveform` |
| 视频倒放 / 视频淡入淡出 | `videoReverse` / `videoFade` |
| 通用格式 / 缩放 / 裁剪 | `mediaConvert` / `mediaScale` / `mediaCrop` |
| 通用旋转 / 色彩 / 锐化 / 叠加 | `mediaRotate` / `mediaColor` / `mediaSharpen` / `mediaOverlay` |
| 元数据删除 / 图片压缩 | `metadataStrip` / `imageCompress` |
| 媒体拼接 / 图片合成视频 | `concatMedia` / `imageToVideo` |

其余类型以应用导出的配置为样板，并对照[视频](../nodes/video.md)、[音频](../nodes/audio.md)、[图片与通用节点](../nodes/image-common.md)。旧类型仍可能为兼容而保留；“模型能读”不表示选择器还提供它。

## 连线字段

```json
{ "id": "c1", "from": "source", "to": "clip", "kind": "data" }
```

| 字段 | 约束 |
| --- | --- |
| `id` | 同一连线列表内唯一 |
| `from` / `to` | 必须是已存在的节点 id，方向不能反 |
| `kind` | `data` 或 `control`；省略时为 `data` |

普通非源节点只有一条数据输入。想拼接多份媒体，要用相应容器和组合节点，不能直接给一个普通节点接多条数据线。数据线也不能连成环；循环由逻辑块描述。

## 几组常用 params

### 源文件

```json
{ "file_media_type": "video" }
```

可用值为 `video`、`audio`、`image`。这代表源素材，不代表最终输出。例如音频波形图的源是 audio，结果却是 image。

### 片段截取

| 键 | 示例 | 含义 |
| --- | --- | --- |
| `start_time` | `2.0` | 起点，秒 |
| `end_time` | `8.0` | 终点，秒 |

要求 `0 <= start_time < end_time`，同时范围应在实际素材内。

### 音频波形图 / 频谱图

```json
{ "width": 1280, "height": 720, "output_format": "png" }
```

宽高用整数像素，界面支持 64～4096；格式用 `png`、`jpg` 或 `webp`。输出是一张静态图片，不是带声音的动态视频。

### 通用节点

```json
{ "media_type": "image" }
```

这是 `params` 的必要组成部分，**不是完整的缩放或转换参数**。还要填写该节点自己的参数。媒体类型应匹配该节点实际支持的类型，不能只为通过填写检查而随便写一个。

### 输出

| 键 | 示例 | 含义 |
| --- | --- | --- |
| `format` | `"keep"` | 跟随当前处理路径的格式选择；也可在界面选具体容器 |
| `naming_mode` | `"suffix"` | `keep` 原名、`suffix` 后缀、`custom` 自定义名 |
| `naming_value` | `"_clip"` | 后缀或自定义名 |
| `output_dir` | `""` | 留空时按应用的输出设置解析 |

`keep` 不表示“完全不处理、永远沿用原扩展名”。上游若已把音频变成图片，最终仍要服从该处理步骤的输出语义。

## 找不到某个参数名，怎么办？

最可靠的办法是做一个小实验：在应用里建一个该类型节点，只改一项，导出旧版后用工具解包，比较前后的 JSON。这样拿到的是当前版本真正保存的键和值。

不要根据显示名称翻译出一个自创键，例如写 `"结束时间"`。程序不读取这个键，它可能被原样保存，却没有任何处理效果。

::: info 从源码核对
图、节点和连线的 JSON 字段可对照[模型序列化实现](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/models/models.dart#L712)。参数默认值主要在对应节点属性编辑器中，执行解释则在图执行器和任务处理代码中。
:::
