# 5.3 字段与参数约束

JSON 配置中较易出错的部分通常是**字段名、值类型和引用关系**，而非缩进格式。

## 图的最外层

| 字段 | 类型 | 用途 |
| --- | --- | --- |
| `nodes` | 对象数组 | 图中的节点 |
| `connections` | 对象数组 | 图中的连线 |
| `logicBlocks` | 对象数组，可省略 | 分组、循环与条件块 |

这些字段应直接位于根对象中。不要额外包装为 `{"graph": {...}}`，也不要将配置库条目的 `name` 和 `graph` 外壳一并作为图数据。

应用模型会为部分缺失字段提供默认值。为减少手写歧义，本教程约定显式填写节点的 `id`、`type`、`params`、`x`、`y`，以及连线的 `id`、`from`、`to`。[Schema](/schemas/pipeline-graph.schema.json)采用这套明确的编写约定，**但不是应用执行规则的完整正式规范**。

## 节点字段

| 字段 | 写法 | 必须留意 |
| --- | --- | --- |
| `id` | 非空字符串 | 节点之间不能重复，连线按它引用 |
| `type` | 已知类型的字符串 | 大小写敏感，例如 `audioWaveform` |
| `params` | 对象 | 数字、布尔和字符串不能随意互换 |
| `x` / `y` | 数字 | 缺省为 0，坐标不影响执行顺序 |
| `gate` | 逻辑门名称，可省略 | 有门时用 `type: "start"`，见下一页 |
| `type_id` | 未知节点保留字段 | 用于新版文件往返，不用于定义自制节点 |

请勿将 UI 中的中文节点名称填入 `type`。例如：

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

普通的非源节点只有一条数据输入。拼接多份媒体时，应使用相应容器和组合节点，不能将多条数据线直接连接到同一个普通节点。数据线不能构成环路；循环由逻辑块描述。

## 常用 params 示例

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

## 参数名核对方法

可通过以下步骤核对参数名：在应用中创建对应类型的节点，只修改一项参数，导出旧版文件后使用工具解包，并比较修改前后的 JSON。该方法可以确定当前版本实际保存的键和值。

请勿根据显示名称自行翻译并创建参数键，例如 `"结束时间"`。程序不会读取此键；该键可能被原样保存，但不会产生处理效果。

::: info 从源码核对
图、节点和连线的 JSON 字段可对照[模型序列化实现](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/models/models.dart#L712)。参数默认值主要在对应节点属性编辑器中，执行解释则在图执行器和任务处理代码中。
:::
