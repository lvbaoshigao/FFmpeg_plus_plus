# 3.7 MCP：让外部 AI 工具访问本机能力

MCP 服务供外部兼容客户端连接 FFmpeg++，读取任务、媒体或当前画布，并在允许范围内操作节点。它与内置 AI 聊天不同：开 MCP 不会替你配置聊天模型，关闭聊天也不能代替关闭 MCP，请分别检查服务开关。

## 先做仅本机连接

1. 打开设置 → AI 中的 MCP 服务。
2. 保留绑定地址 <code>127.0.0.1</code>，确认端口；默认端口为 <code>3000</code>。
3. 开启服务，确认运行状态。修改地址或端口后，点“应用”重启服务并采用新值。
4. 在外部客户端配置 HTTP JSON-RPC 连接，例如 <code>http://127.0.0.1:3000/</code>。客户端必须支持这里的请求/响应方式，不能只支持 stdio。
5. 从只读操作开始，例如列工具或任务。操作当前画布前，先在 FFmpeg++ 打开节点编辑器。

不同客户端的配置格式不同。先确认连接类型、URL 和端口，再按客户端说明填写，不建议直接照抄另一款客户端的完整配置。

## 先验证能不能列工具

下面只列出工具，不执行改图操作；按实际端口替换地址。

~~~bash
curl -X POST http://127.0.0.1:3000/ -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
~~~

服务实现 initialize、ping、tools/list、tools/call、resources/list、resources/read 等方法。它提供工具和资源，不代表已支持客户端要求的全部 MCP 扩展、事件流或长连接行为。

| 能力 | 例子 | 先检查 |
| --- | --- | --- |
| 查看状态 | 列任务、日志、媒体、容器 | 对应权限 |
| 查看画布 | 节点、连线、图统计、错误检查 | 当前编辑器是否打开 |
| 修改画布 | 增删节点、连线、改参数、撤销/重做、保存 | MCP 写入权限 |
| 文件信息 | 列目录、读取媒体信息、探测 | 文件系统权限与路径 |
| 任务控制 | 查看任务、取消任务 | 目标是否正确，取消会影响真实运行 |

MCP 的“允许写入”“允许文件系统访问”独立于内置 AI 读写权限。工具显示在列表里，也可能因权限关闭而不能执行。

## 局域网连接

默认回环地址只供本机访问。确实需要另一设备连接时，可以改监听地址，例如 <code>0.0.0.0</code>，客户端使用本机实际局域网 IP，而不是 0.0.0.0。

非回环监听会生成访问令牌。客户端选择一种认证头：

~~~text
Authorization: Bearer <界面显示的访问令牌>
~~~

或：

~~~text
x-mcp-token: <界面显示的访问令牌>
~~~

重启服务后可能生成新令牌，请重新核对。不要把令牌和日志一起贴到公开 issue。当前是 HTTP 服务，教程不承诺内置 TLS 或适合直接暴露公网。

## 连不上时按顺序查

1. 看服务状态与错误，确认监听成功。
2. 先测本机，再查局域网地址、防火墙与认证。
3. 401：检查令牌和请求头，尤其是改地址/重启后。
4. 找不到当前画布：先打开编辑器；已关闭的画布不继续作为活动画布。
5. 权限不足：核对 MCP 自己的权限，不是聊天权限。

### 实现依据

- [监听、默认地址和令牌](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/providers/app_state.dart#L4760-L4857)
- [认证头及请求处理](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/providers/app_state.dart#L4940-L5053)
- [方法与资源](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/providers/app_state.dart#L5078-L5224)
- [设置入口与独立权限](https://github.com/lvbaoshigao/FFmpeg_plus_plus/blob/main/ffmpegpp_gui/lib/pages/ai_settings_mobile.dart#L2619-L2725)
