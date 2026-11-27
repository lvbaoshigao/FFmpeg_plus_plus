# 3.6 AI 助手配置与使用

AI 助手位于节点编辑器中，可结合当前画布讨论处理方法、生成流程、修改节点参数，并通过工具执行检查。使用前须配置模型服务；应用不提供无需配置即可持续使用的内置备用模型。

## 模型服务连接步骤

1. 进入设置 → AI，启用 AI 服务。
2. 新建或编辑提供商，核对 API Base URL、请求路径与 API Key，避免在基础地址与请求路径中重复包含同一路径段。
3. 在模型页获取服务端模型列表，或添加自定义模型，然后启用并选择目标模型。
4. 根据服务的实际能力设置模型标记，例如是否支持视觉。能力标记仅影响客户端请求构造，不会增加服务端模型的能力。
5. 保存提供商配置，按需测试连接，再返回节点编辑器打开“AI 助手”。
6. 首次发送范围明确的请求，例如“解释当前流程，不修改；指出裁剪与缩放的执行顺序”。

> **当前对话入口不支持 Responses API。** 设置中仍保留该选项，但发送时会拒绝请求，并提示切换至 Chat Completions。API Key 或模型名称为空时，也会停止发送并提示补充配置。

提供商配置还支持分组、多 Key、代理、自定义请求头、余额查询与模型参数。多 Key 轮换不会增加服务商分配的总配额。余额接口缺少统一标准，查询失败不表示 Key 一定不可用。单模型参数可覆盖提供商默认值。

## 请求描述与结果验证

请求中应明确处理目标、输出约束与确认要求，例如：

> 将当前视频缩到 1920×1080 范围内，保持纵横比，音频保留。先说明要添加或修改哪些节点，等我确认再应用。

收到结果后，应核对输入类型、被替换的节点、输出路径、编码器、尺寸与音轨。通过图校验后，先使用短素材执行验证。模型生成某个参数名称，不表示当前 FFmpeg、硬件或节点实现支持该参数。

## 权限与操作确认机制

| 选项 | 作用 |
| --- | --- |
| 读取权限 | 允许读取文件信息、目录等对应能力 |
| 写入权限 | 允许修改节点参数、应用管线等对应能力 |
| 自动执行工具 | 影响提问、检查、撤销等工具的自动处理 |
| 允许 AI 询问用户 | 允许模型通过选项主动提问 |
| 会话模式：询问 / 自动 | 控制图应用等操作是否需要确认 |
| 跳过询问 | 仅在询问模式下，让勾选操作不再弹确认 |

上述选项分别控制不同能力。首次使用时，可保留询问模式，再按需要启用相应权限。高级页的“图生成”区分整图重画与修改选中节点；仅修改局部时，须确认选区与操作模式。

## 附件、历史与长会话

本地附件的添加不表示所有文件内容均会上传并解析。普通附件主要提供名称、路径、大小等元数据；仅对标记支持视觉的模型附带符合限制的图片内容。

- 最多 8 个附件。
- 单张内联图片最大 8 MiB；一次请求的图片总预算为 20 MiB，包含历史图片。
- 没有本地路径的来源需复制到临时文件，复制上限为 64 MiB。
- 图片发送至所配置的模型服务，普通附件的路径元数据也会进入上下文；发送前须核对相关内容。

历史入口支持重新打开已有会话与删除记录。上下文不足时，应用会减少输出预算或略去部分旧历史；界面中可见的历史内容不保证全部包含在当前请求中。大画布与较长提示仍可能超过预算。

外部 AI 客户端连接本机的配置方法见[MCP 接入](mcp.md)。

### 实现依据

- [提供商连接和管理字段](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/ai_settings_mobile.dart#L3851-L4118)
- [权限设置](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/ai_settings_mobile.dart#L2513-L2550)
- [会话模式与跳过询问](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/ai_settings_mobile.dart#L5185-L5337)
- [发送限制和上下文预算](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/pipeline_editor_page.dart#L15274-L15436)
- [附件限额](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/ai_chat_attachments.dart#L52-L55)
- [图片与元数据组装](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/services/ai_chat_attachments.dart#L145-L200)
