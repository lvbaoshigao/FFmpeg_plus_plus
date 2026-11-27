# 5.4 加入逻辑门和逻辑块

掌握串行处理链后，可通过控制线添加逻辑门。建议先使用最简单的“恒 1”门，其结果明确，便于验证连线配置。

## 逻辑门的 type 字段

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

该节点不是第二个媒体源。程序检测到 `gate` 后会将其作为逻辑门处理。

### 添加控制线

在原来的 `connections` 数组里加：

```json
{ "id": "c3", "from": "enabled", "to": "clip", "kind": "control" }
```

原有两条数据线必须保留。控制线传递使能信号，不能替代媒体输入。

| 线 | 从哪儿到哪儿 | 作用 |
| --- | --- | --- |
| data | source → clip → output | 传递媒体数据 |
| control | enabled → clip | 决定 clip 是否使能 |

本例使用恒 1 门，使截取节点保持启用。在只包含一个处理步骤的链中，不应将其改为恒 0 并期待系统“自动输出原片”；禁用最后一个处理步骤可能导致执行计划构建失败。

## 逻辑门名称

`gate` 使用以下大小写准确的名称：

- 布尔运算：`and`、`or`、`not`、`nand`、`nor`、`xor`、`xnor`。
- 常量：`const1`、`const0`。
- 其他：`timeTrigger`、`random`、`filenameMatch`、`extensionMatch`。

文件中的门名可能与 AI 工具接受的别名不同，例如此处使用 `timeTrigger`。涉及时间、概率或文本参数时，应先从界面导出相应逻辑门作为样例，避免猜测字段名。

::: warning 实现限制
普通节点的状态输出不能直接连接至另一个普通节点的使能输入；当前保存校验要求使能端的信号来自逻辑门。文本匹配门不会自动读取当前输入文件名，而是根据当前实现中的配置文本求值。详细限制见[逻辑节点教程](../nodes/logic.md)。
:::

## 逻辑块配置

分组或循环不是普通处理节点，而是图顶层 `logicBlocks` 数组中的项目。例如，以下配置为 clip 添加纯分组框：

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

注意：`childNodeIds` 中的字符串必须对应 `nodes` 中的节点。节点位于框内并不会自动成为块成员；**成员关系由 ID 列表决定**。

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

上述参数属于某个 loop 块的 `params`，不是图顶层字段。`accumulate` 决定循环是否以上一轮结果继续处理。实现累积效果前，请先查阅[逻辑块执行语义](../nodes/logic.md)。

## 约束与验证要求

- 一个处理节点不能同时属于多个块。
- 块里不能放源文件、输出或逻辑门。
- 循环上限为 10000 次，但该上限不是建议使用值；验证时建议先使用 2 次。
- 选择性循环的随机选择当前尚未实现，因此不能将其作为可靠的随机流程。
- 条件块跳过最后处理步骤时存在额外执行边界。应通过界面和短素材进行检查，不能仅凭 JSON 推断结果。

可以直接下载[完整控制与分组示例](/examples/controlled-clip.json)。最后仍需[封装和导入](./pack-import.md)。
