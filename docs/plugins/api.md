# 插件清单与 API v1

插件包扩展名为 .fppplugin，内容为 ZIP，根目录必须有 manifest.json。WASM 插件通过 module 指定一个相对 .wasm 路径；只提供主题或 AI 目录的数据包可省略 module。禁止绝对路径、目录穿越、符号链接及不受支持的清单字段。SDK 提供对应 JSON Schema；宿主仍执行更严格的语义和资源校验。

## 最小结构

~~~json
{
  "format_version": 1,
  "id": "org.example.audio-tools",
  "api_version": 1,
  "app_version": ">=6.0.0-beta2 <7.0.0",
  "Basic_info": {
    "Name": "Audio Tools",
    "Version": "1.0.0",
    "IsPreview": true,
    "Summary": "Audio tools implemented through the host API."
  },
  "module": "plugin.wasm",
  "Node_info": [],
  "permissions": {"files": {"read": false, "write": false}, "network": []},
  "limits": {"memory_mb": 16, "time_ms": 1000, "fuel": 1000000},
  "dependencies": []
}
~~~

Basic_info 必需；字段大小写固定。ID 是小写反向域名，Version 为语义版本。安装、启用和调用受 api_version、app_version 与依赖约束控制。

## 节点声明及宿主 UI 扩展

~~~json
{
  "id": "audio_gain",
  "name": "Audio Gain",
  "fun": "Adjust audio gain in decibels.",
  "IsLogic": true,
  "IO": {"inputs": 1, "outputs": 1},
  "input_types": ["audio"],
  "output_type": "audio",
  "schema_version": 1,
  "fields": [
    {"key": "decibels", "label": "Gain (dB)", "type": "number", "default": -6, "min": -60, "max": 12}
  ]
}
~~~

- 未在 Node_info 中声明的节点不会注册。v1 数据节点固定一入一出，input_types 接受 video/audio/image 的非空去重子集，output_type 为其中一种媒体类型。
- IsLogic 表示是否允许现有使能/状态控制连接，与声明布尔门类型不同。宿主保持既有数据流与控制流的语义。
- fields 支持 number、integer、string、boolean、select；每项有稳定 key、label、type 和 default。数值可带 min/max；select 使用去重字符串 options，默认值必须属于选项。
- **UI 是宿主 API。** 插件只返回字段声明和业务数据，Flutter 组件、输入校验、布局及无障碍交互由宿主现有控件实现。不能把任意 Widget、Dart 源码、HTML 或 native UI 注入应用。
- 图中保存插件 ID、节点 ID、插件版本、schema_version、参数及显示快照。执行必须根据当前启用的真实声明重新校验；图中快照不能扩大能力、参数范围或权限。

## WASM ABI

目标为 WASM32，无 WASI、guest 线程、Core start section 或自动初始化导出。导入限定为下表两个函数，模块名固定 ffmpegpp：

| 导入 | WASM 类型 | 作用 |
| --- | --- | --- |
| request_read | (i32 pointer, i32 capacity) → i32 | 复制 UTF-8 JSON 请求到 guest 线性内存；返回复制字节数，容量不足或错误返回负值 |
| response_write | (i32 pointer, i32 length) → i32 | 提交一个有界 UTF-8 JSON 响应；成功返回长度，错误返回负值 |

长度为字节数，数据不附加 NUL。SDK 的 fpp_read_json 会留出一个 NUL 位置以便示例解析；调用者必须检查负返回值。响应不能是 WASM 指针、任意字符串或输出路径。请求和响应各不超过 256 KiB；较小的 guest 缓冲区也应明确拒绝过长请求。

业务导出全部为 **void(void)**，并导出 memory。宿主使用全新的实例调用，不保留 guest 内存状态：

| 导出 | 必需条件 | 请求 | 响应 |
| --- | --- | --- | --- |
| Basic_info | 有 WASM module 时必需 | JSON 对象 | 直接返回与清单一致的 Basic_info 对象 |
| Node_info | 声明节点时必需 | JSON 对象 | {nodes:[与清单一致的节点声明]} |
| Node_editor_add | 可选 | 带 node_id | {fields:[字段声明]}；没有此导出时用清单 fields |
| Node_execute | 可执行节点需要 | 见下例 | 安全操作描述或有界宿主请求 |

~~~c
#include "ffmpegpp_plugin.h"
FPP_EXPORT(Basic_info) void Basic_info(void) {
    FPP_RESPOND_LITERAL("{\"Name\":\"My Plugin\",\"Version\":\"1.0.0\",\"IsPreview\":true,\"Summary\":\"Example\"}");
}
~~~

上面的片段只展示 ABI，完整可编译模块由 SDK 的 audio-gain 示例提供。不要额外导出 _start、__wasm_call_ctors、__post_instantiate 或 _initialize。

### 节点执行

~~~json
{
  "api_version": 1,
  "plugin_id": "org.ffmpegpp.examples.audio-gain",
  "node_id": "audio_gain",
  "params": {"decibels": -6},
  "media_type": "audio"
}
~~~

v1 允许下列最终结果：

| operation | 参数 | 宿主行为 |
| --- | --- | --- |
| audio.volume | decibels 为有界有限数值 | 通过现有音频音量流程执行 |
| video.flip | axis 为 horizontal 或 vertical | 通过现有视频翻转流程执行 |
| video.scale | width、height 为合法正整数 | 通过现有视频缩放流程执行 |
| media.copy | 无 | 由宿主复制当前媒体 |

宿主再次验证媒体兼容、数值和允许操作，再构造现有 BackendCall。返回 arbitrary action、shell、过滤器字符串或任意输入/输出路径都不会成为执行权限。

### 可选宿主 I/O

额外能力也经这两个导入传递。需要 I/O 时，业务导出返回：

~~~json
{
  "host_request": {"id": "load-settings", "method": "file.read", "path": "settings.json"},
  "continuation": {"stage": "loaded"}
}
~~~

宿主校验权限、私有目录/精确 origin、配额和剩余时间后，重新实例化并调用同一导出，在原请求上附 continuation 和 host_response：

~~~json
{"host_response":{"id":"load-settings","ok":false,"error":"Permission denied"},"continuation":{"stage":"loaded"}}
~~~

成功结果位于 host_response.result：

| method | 请求额外字段 | result |
| --- | --- | --- |
| file.read | path | {content_base64, bytes} |
| file.write | path、content_base64 | {bytes} |
| http.get | url | {status, content_base64, content_type} |

bytes 是解码后的内容字节数。单次内容上限 128 KiB、整轮累计上限 2 MiB；单插件私有 data 最多 16 MiB、256 个文件。http.get 不跟随重定向，不发送环境凭据；非 2xx 状态仍需由插件检查 status，不能把 HTTP 请求成功等同于业务成功。

权限或路径错误通过 ok=false 返回；超时、预算耗尽和取消直接终止调用，不再向 guest 续调。一次逻辑调用最多 16 个宿主请求，请求 ID 不能重复；所有实例重建与 I/O 共用清单 time_ms 的整轮墙钟预算。每次实例是新的，因此续调状态必须放在有界 JSON continuation 中。权限和包大小细节见 [安全与兼容性](./security.md)。
