# 5.4 加入逻辑门和逻辑块

串行链会写了，再试一条控制线。先用最简单的“恒 1”，因为它的结果明确，方便确认自己有没有接对。

## 逻辑门为什么也写 type=start？

当前模型复用 `start` 作为逻辑门的占位类型，真正区分门的是 `gate` 字段：

```json
{
  "id": "enabled",
  "type": "start",
  "gate": "const1",
  "params": {},
  "x": 100,
  "y": 400
}
```

这不是第二个媒体源。程序识别到 `gate` 后，会按逻辑门处理。

### 写一条控制线

在原来的 `connections` 数组里加：

```json
{ "id": "c3", "from": "enabled", "to": "clip", "kind": "control" }
```

原有两条数据线仍要保留。控制线传的是使能信号，不能代替媒体输入。

| 线 | 从哪儿到哪儿 | 作用 |
| --- | --- | --- |
| data | source → clip → output | 传递媒体数据 |
| control | enabled → clip | 决定 clip 是否使能 |

本例用恒 1，让截取保持启用。不要在这条只剩一个处理步骤的链里把它改成恒 0 来期待“自动输出原片”：禁用最后处理步骤可能使执行计划构建失败。

## 门名称写法

`gate` 使用以下大小写准确的名称：

- 布尔运算：`and`、`or`、`not`、`nand`、`nor`、`xor`、`xnor`。
- 常量：`const1`、`const0`。
- 其他：`timeTrigger`、`random`、`filenameMatch`、`extensionMatch`。

文件里的门名与 AI 工具接受的别名不一定相同，例如这里是 `timeTrigger`。需要时间、概率或文本参数时，先从界面导出对应门作为样板，不要猜字段。

::: warning 两个实际限制
普通节点的状态输出不能直接接另一个普通节点的使能输入，当前保存校验要求使能端来自逻辑门。文本匹配门也不能直接理解为“自动读取当前输入文件名”；它按当前实现中的配置文本求值。详细边界见[逻辑节点教程](../nodes/logic.md)。
:::

## 逻辑块是另一个数组

分组或循环不是一个普通处理节点，而是图顶层的 `logicBlocks` 项。比如给 clip 套一个纯分组框：

```json
"logicBlocks": [
  {
    "id": "group1",
    "type": "group",
    "name": "截取步骤",
    "childNodeIds": ["clip"],
    "params": {},
    "x": 330,
    "y": 110,
    "width": 290,
    "height": 190
  }
]
```

注意：`childNodeIds` 里的字符串要能在 `nodes` 中找到。框画在节点外面，不等于自动把节点加入了块；**成员关系由 ID 列表决定**。

| type | 作用 | 参数方向 |
| --- | --- | --- |
| `group` | 组织节点，不重复执行 | 可用空 params |
| `loop` | 重复执行块内处理 | `countMode`、`count`、`accumulate` 等 |
| `selectiveLoop` | 选择性执行和重复 | 还涉及选择模式与成员列表 |
| `condition` | 按输入文件属性判断 | `condField`、`condOp`、`condValue`、`condElse` |

固定两轮的核心参数可以写成：

```json
{ "countMode": "fixed", "count": 2, "accumulate": false, "onError": "stop", "retries": 0 }
```

它属于某个 loop 块的 `params`，不是图顶层字段。`accumulate` 决定循环是否以上一轮结果继续处理；要做累积效果前，先看[逻辑块执行语义](../nodes/logic.md)。

## 哪些地方不能省检查？

- 一个处理节点不能同时属于多个块。
- 块里不能放源文件、输出或逻辑门。
- 循环上限为 10000 次，但上限不是建议值；先用 2 次验证。
- 选择性循环的随机选择当前未实现，不能把它当作可靠的随机流程。
- 条件块跳过最后处理步骤有额外执行边界，先用界面和短素材检查，不要仅凭 JSON 推断结果。

可以直接下载[完整控制与分组示例](/examples/controlled-clip.json)。最后仍需[封装和导入](./pack-import.md)。
