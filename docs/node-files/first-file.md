# 5.2 创建第一张节点图

本页沿用[入门任务](../guide/first-task.md)中的示例：截取视频第 2 秒至第 8 秒的内容。此处通过文本编写配置，而不是在画布上拖放节点。

## 先把完整例子存下来

创建 `clip-video.json` 并以 UTF-8 编码保存，也可直接[下载示例](/examples/clip-video.json)。

```json
{
  "nodes": [
    {
      "id": "source",
      "type": "start",
      "params": {
        "file_media_type": "video"
      },
      "x": 80,
      "y": 160
    },
    {
      "id": "clip",
      "type": "clip",
      "params": {
        "start_time": 2.0,
        "end_time": 8.0
      },
      "x": 380,
      "y": 160
    },
    {
      "id": "output",
      "type": "output",
      "params": {
        "format": "keep",
        "naming_mode": "suffix",
        "naming_value": "_clip",
        "output_dir": ""
      },
      "x": 700,
      "y": 160
    }
  ],
  "connections": [
    {
      "id": "c1",
      "from": "source",
      "to": "clip"
    },
    {
      "id": "c2",
      "from": "clip",
      "to": "output"
    }
  ]
}
```

该图表示：**源视频输入 clip 节点，clip 的处理结果输入 output 节点。**

## 三类主要图字段

### 第一部分：nodes 定义节点

- `id` 是图中引用节点的标识。本例使用 `source`、`clip`、`output`；该字段不要求使用 UUID。
- `type` 是程序使用的类型标识。片段截取节点应填写 `clip`，而非中文名称“片段截取”。
- `params` 放参数。不同类型的节点读取不同字段。
- `x`、`y` 是画布坐标，只影响摆放，不决定先后。

### 第二部分：connections 定义连线

`c1` 的 `from` 为 `source`、`to` 为 `clip`，因此该连线将源节点连接到截取节点。`c2` 将截取结果连接到输出节点。

更改数组中的节点顺序**不会改变连线关系**；连线仍按 ID 引用节点。

### 第三部分：输出节点配置路径与文件名

本例保留处理结果所需的格式选择，并为文件名添加 `_clip` 后缀。`output_dir` 留空时，输出位置遵循应用的输出目录规则。运行前应在界面中确认实际输出位置。

## 修改示例参数

若需将截取范围改为第 1.5 秒至第 5 秒，只需修改：

```json
"params": {
  "start_time": 1.5,
  "end_time": 5.0
}
```

此处时间单位为**秒**，不是毫秒。`end_time` 表示结束位置，不表示持续时长。目标范围长度为 3.5 秒；实际媒体时间戳和处理路径仍会影响精确结果。

然后将输出后缀改为 `_short`：

```json
"naming_mode": "suffix",
"naming_value": "_short"
```

以上两个代码块均为**局部片段**，应替换对应位置，不能作为独立的完整图文件使用。

::: tip 时间数值格式
本例将时间写为 `2.0`、`8.0`。当前截取编辑器的部分预览代码按浮点值读取时间，因此手动编写时应沿用此格式。`"2.0"` 带引号时是字符串，不能替代数字。
:::

## 输入媒体来源

该配置可重复使用；输入媒体来自项目页中选择的文件。`file_media_type: "video"` 用于声明源类型，不是媒体路径，也不会将视频嵌入文件。

字幕、叠加图片等节点使用的外部文件不会自动打包进 .fppx。共享配置时，应另行提供这些资源，并由接收方重新选择路径。

下一步：[把 JSON 封装并导入](./pack-import.md)。其他字段说明见[字段参考](./schema.md)。
