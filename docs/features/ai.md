# 3.6 AI 助手：先配置，再让它帮你改流程

AI 助手位于节点编辑器里，可以结合当前画布讨论处理方法、生成流程、修改节点参数，并通过工具做检查等操作。它需要你配置模型服务；没有一个无需配置、永远可用的内置模型兜底。

## 第一次连接

1. 到设置 → AI，打开 AI 服务。
2. 新建或编辑提供商，核对 API Base URL、请求路径和 API Key。不要把同一段路径重复拼进地址与请求路径。
3. 在模型页获取服务端列表，或添加自定义模型，启用并选择要用的模型。
4. 根据服务实际能力标记模型，例如是否支持视觉。勾选能力不会让服务端模型凭空获得该能力。
5. 保存提供商配置；需要时先测试连接，再回节点编辑器打开“AI 助手”。
6. 先发一条范围明确的请求，例如“解释当前流程，不修改；指出裁剪与缩放的执行顺序”。

> **当前不要选 Responses API 来聊天。** 设置里仍有这个选项，但实际发送会明确拒绝，并提示切换 Chat Completions。Key 或模型为空也会停止发送并提示配置。

提供商还支持分组、多 Key、代理、自定义请求头、余额查询和模型参数。多 Key 轮换不代表服务商给了你更多总配额；余额接口没有统一标准，查不到余额不等于 Key 一定不可用。单模型参数可覆盖提供商默认值。

## 把需求说得可检查

与其说“帮我优化视频”，可以说：

> 将当前视频缩到 1920×1080 范围内，保持纵横比，音频保留。先说明要添加或修改哪些节点，等我确认再应用。

收到结果后，检查输入类型、被替换的节点、输出路径、编码器、尺寸和音轨。通过图校验后，先用短样例实际运行。AI 认识某个参数名称，不等于当前 FFmpeg、硬件或节点实现支持它。

## 权限和“是否询问”分别管什么

| 选项 | 作用 |
| --- | --- |
| 读取权限 | 允许读取文件信息、目录等对应能力 |
| 写入权限 | 允许修改节点参数、应用管线等对应能力 |
| 自动执行工具 | 影响提问、检查、撤销等工具的自动处理 |
| 允许 AI 询问用户 | 允许模型通过选项主动提问 |
| 会话模式：询问 / 自动 | 控制图应用等操作是否需要确认 |
| 跳过询问 | 仅在询问模式下，让勾选操作不再弹确认 |

这些不是同一个总权限。初次使用可保留询问模式，再按需求开放能力。高级页“图生成”还区分整图重画与修改选中节点；只想改局部时，先检查选区和模式。

## 附件、历史与长会话

可以添加本地附件，但不代表任何文件都会全文上传并解析。普通附件主要提供名称、路径、大小等元数据；只有标记支持视觉的模型，才会附带符合限制的图片内容。

- 最多 8 个附件。
- 单张内联图片最大 8 MiB；一次请求的图片总预算为 20 MiB，包含历史图片。
- 没有本地路径的来源需复制到临时文件，复制上限为 64 MiB。
- 图片会发给你配置的模型服务，普通附件路径元数据也进入上下文；发送前检查内容。

历史入口可以重新打开已有会话、删除不再需要的记录。上下文不足时会减少输出预算或略去部分旧历史；屏幕里看得到，不代表这一轮模型完整读到了。大画布和大段提示仍可能超过预算。

外部 AI 连接本机是另一项功能，见[MCP 接入](mcp.md)。

### 实现依据

- [提供商连接和管理字段](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/ai_settings_mobile.dart#L3851-L4118)
- [权限设置](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/ai_settings_mobile.dart#L2513-L2550)
- [会话模式与跳过询问](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/ai_settings_mobile.dart#L5185-L5337)
- [发送限制和上下文预算](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/pipeline_editor_page.dart#L15274-L15436)
- [附件限额](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/ai_chat_attachments.dart#L52-L55)
- [图片与元数据组装](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/ai_chat_attachments.dart#L145-L200)
