# 3.7 MCP 服务与外部客户端接入

MCP 服务允许外部兼容客户端连接 FFmpeg++，读取任务、媒体或当前画布，并在授权范围内操作节点。MCP 与内置 AI 对话分别配置：启用 MCP 不会配置聊天模型，关闭聊天也不会关闭 MCP。应分别核对两个服务的开关。

## 本机连接配置

1. 打开设置 → AI 中的 MCP 服务。
2. 保留绑定地址 <code>127.0.0.1</code>，确认端口；默认端口为 <code>3000</code>。
3. 开启服务并确认运行状态。修改地址或端口后，点击“应用”重启服务，使新配置生效。
4. 在外部客户端配置 HTTP JSON-RPC 连接，例如 <code>http://127.0.0.1:3000/</code>。客户端必须支持这里的请求/响应方式，不能只支持 stdio。
5. 首先执行只读操作，例如列出工具或任务。操作当前画布前，须在 FFmpeg++ 中打开节点编辑器。

不同客户端使用不同配置格式。应先核对连接类型、URL 与端口，再按对应客户端的说明配置，避免直接复用其他客户端的完整配置。

## 工具列表验证

以下请求仅列出工具，不修改节点图。执行前应按实际端口调整地址。

~~~bash
curl -X POST http://127.0.0.1:3000/ -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
~~~

服务实现 initialize、ping、tools/list、tools/call、resources/list、resources/read 等方法。它提供工具和资源，不代表已支持客户端要求的全部 MCP 扩展、事件流或长连接行为。

| 能力 | 操作示例 | 前提条件与检查项 |
| --- | --- | --- |
| 查看状态 | 列任务、日志、媒体、容器 | 对应权限 |
| 查看画布 | 节点、连线、图统计、错误检查 | 当前编辑器是否打开 |
| 修改画布 | 增删节点、连线、改参数、撤销/重做、保存 | MCP 写入权限 |
| 文件信息 | 列目录、读取媒体信息、探测 | 文件系统权限与路径 |
| 任务控制 | 查看任务、取消任务 | 目标是否正确，取消会影响真实运行 |

MCP 的“允许写入”与“允许文件系统访问”独立于内置 AI 的读写权限。工具出现在列表中，不表示相应权限已启用。

## 局域网连接

默认回环地址仅供本机访问。需要从其他设备连接时，可修改监听地址，例如 <code>0.0.0.0</code>；客户端须连接服务所在设备的实际局域网 IP，不能将 0.0.0.0 用作目标地址。

非回环监听会生成访问令牌。客户端选择一种认证头：

~~~text
Authorization: Bearer <界面显示的访问令牌>
~~~

或：

~~~text
x-mcp-token: <界面显示的访问令牌>
~~~

重启服务后可能生成新令牌，连接前须重新核对。公开提交日志时，不应包含访问令牌。当前服务使用 HTTP；本教程不提供内置 TLS 或直接暴露公网的配置保证。

## 连接异常排查

1. 检查服务状态与错误，确认监听成功。
2. 先验证本机连接，再检查局域网地址、防火墙与认证。
3. 401：检查令牌和请求头，尤其是改地址/重启后。
4. 找不到当前画布：先打开编辑器；已关闭的画布不继续作为活动画布。
5. 权限不足：核对 MCP 服务的权限配置；内置聊天权限不适用于 MCP。

### 实现依据

- [监听、默认地址和令牌](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/providers/app_state.dart#L4760-L4857)
- [认证头及请求处理](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/providers/app_state.dart#L4940-L5053)
- [方法与资源](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/providers/app_state.dart#L5078-L5224)
- [设置入口与独立权限](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/ai_settings_mobile.dart#L2619-L2725)
