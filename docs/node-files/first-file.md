# 5.2 写出第一张节点图

我们继续用[入门任务](../guide/first-task.md)的例子：从视频第 2 秒截到第 8 秒。区别只是，这次不在画布上拖节点，而是在文本里写。

## 先把完整例子存下来

新建 `clip-video.json`，按 UTF-8 保存。也可以直接[保存这份示例](/examples/clip-video.json)。

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

这张图可以读成一句话：**源视频交给 clip 节点，clip 的结果交给 output 节点。**

## 把三块内容对上画布

### 第一块：nodes 决定“有哪些节点”

- `id` 是这张图里引用节点的名字。本例用 `source`、`clip`、`output`，足够直观；不强制必须是 UUID。
- `type` 是程序使用的类型标识。片段截取要写 `clip`，不能写中文“片段截取”。
- `params` 放参数。不同类型的节点读取不同字段。
- `x`、`y` 是画布坐标，只影响摆放，不决定先后。

### 第二块：connections 决定“接给谁”

`c1` 的 `from` 是 `source`、`to` 是 `clip`，所以它把源连到截取节点。`c2` 再把截取结果连到输出。

把数组里的节点顺序交换，**不会代替改连线**。连线仍然按 ID 找节点。

### 第三块：输出节点决定“放哪儿、叫什么”

本例保留处理结果所需的格式选择，并给文件名加 `_clip` 后缀。`output_dir` 留空，跟随应用设置的输出目录规则。运行前请在界面中确认实际输出位置。

## 动手改两处

假设想改成“保留第 1.5 秒到第 5 秒”，只改：

```json
"params": {
  "start_time": 1.5,
  "end_time": 5.0
}
```

这里的时间单位是**秒**，不是毫秒。`end_time` 是结束位置，不是持续时长。目标范围长度为 3.5 秒，实际媒体时间戳和处理路径仍会影响精确结果。

再把输出后缀改成 `_short`：

```json
"naming_mode": "suffix",
"naming_value": "_short"
```

上面两个代码块是**局部片段**，替换对应位置即可，不要把它们当成两个独立的完整图文件。

::: tip 时间数值保留小数点
本例把时间写成 `2.0`、`8.0`。当前截取编辑器的部分预览代码按浮点值读取时间，手写时沿用这种写法更稳妥。`"2.0"` 带引号是字符串，不能替代数字。
:::

## 为什么没写 input.mp4？

这是一份可复用的配置，真正输入来自你在项目页选中的媒体。`file_media_type: "video"` 声明源类型，不是媒体路径，也不会把视频嵌进文件。

字幕、叠加图片等节点若使用外部文件路径，那些资源也不会自动打进 .fppx。共享配置时要另外提供资源，并在接收端重新选路径。

下一步：[把 JSON 封装并导入](./pack-import.md)。想先多了解几个字段，可看[字段参考](./schema.md)。
