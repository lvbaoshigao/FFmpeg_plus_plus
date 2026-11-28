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

Basic_info 必需；字段大小写固定。ID 是小写反向域名，Version 为语义版本。Author 可选（非空显示名，最多 120 字符）；Icon 可选，使用包内相对路径指向 PNG/JPEG/WebP/GIF 图像，必须符合包路径与文件安全限制。安装、启用和调用受 api_version、app_version 与依赖约束控制。

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

- 未在 Node_info 中声明的节点不会注册。v1 数据节点固定一入一出；input_types 是 video/audio/image 的非空去重子集，output_type 独立声明一种目标媒体类型，两者可以不同。当前只有 ffmpeg.execute 支持跨媒体类型转换；旧 operation 仍要求输入与输出同类型。
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

C/C++ SDK 还提供两个仅头文件 helper：`include/ffmpegpp_json.h` 的 `fpp_json_doc`/`fpp_json_value` 是对调用方 JSON 缓冲区的有界视图；`fpp_json_parse`、`fpp_json_root`、`fpp_json_object_get`、`fpp_json_lookup`、`fpp_json_array_length`/`fpp_json_array_at` 与 `fpp_json_get_i32`/`i64`/`number`/`bool`/`string` 提供结构化读取。字符串 getter 解码 UTF-8 转义到调用方 buffer（capacity 包含末尾 NUL）；无效 UTF-8 与嵌入 NUL 会拒绝。`fpp_host_capabilities_init` 从 request 的 `host` 对象读取宿主能力，并可用 `fpp_host_supports_operation`、`fpp_host_supports_ffmpeg_option` 与 `fpp_host_supports_ffmpeg_filter` 检查声明项。

`include/ffmpegpp_ffmpeg.h` 提供有界计划 writer：`fpp_ffmpeg_plan_init`、`fpp_ffmpeg_plan_set_capabilities`、`fpp_ffmpeg_plan_add_argument`、`fpp_ffmpeg_plan_add_option`、`fpp_ffmpeg_plan_add_filter`、`fpp_ffmpeg_plan_write`/`end` 与 `fpp_ffmpeg_plan_respond`。该计划只生成 `{operation, arguments}`，不接收输入/输出路径。`add_filter` 是简单视频 `-vf` 的便利封装；音频 `-af` 与 `-filter_complex` 使用 `add_option`。helper 提供缓冲区、参数数目及部分 capability 预检；完整滤镜语法、服务端公布的 UTF-8 参数字节上限和最终安全验证仍由 backend 执行。

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
  "media_type": "audio",
  "input_media_type": "audio",
  "output_media_type": "audio"
}
~~~

`Node_execute` 也可用严格的单键 `{"error":"..."}` 返回面向用户的错误说明：值必须是非空白字符串，最多 2048 字符且不含 NUL；不能与 `operation` 等字段混合。此结果由宿主拒绝执行并显示说明，不会启动媒体处理。

v1 允许下列最终结果：

| operation | 参数 | 宿主行为 |
| --- | --- | --- |
| audio.volume | decibels 为有界有限数值 | 通过现有音频音量流程执行 |
| video.flip | axis 为 horizontal 或 vertical | 通过现有视频翻转流程执行 |
| video.scale | width、height 为合法正整数 | 通过现有视频缩放流程执行 |
| media.copy | 无 | 由宿主复制当前媒体（输入、输出同类型） |
| ffmpeg.execute | arguments：FFmpeg 输出选项字符串数组 | 仅在 backend 实际声明支持时开放；按发现的选项/滤镜白名单和参数上限校验，再由宿主绑定输入与输出并提交现有任务队列。仅此 operation 可声明跨媒体类型。 |

宿主再次验证媒体兼容、数值和允许操作，再构造执行任务。WASM 请求中的 `media_type` 保持为输入类型（兼容旧字段）；`input_media_type` 与它一致，`output_media_type` 由宿主依据已安装插件的 live 节点声明确定和校验，不能由图快照或 guest 越权修改。节点始终固定一入一出，只有 `ffmpeg.execute` 可跨类型转换；旧 operation 要求输入、输出同类型。backend 若不支持该操作，宿主不会发布 `ffmpeg.execute` 或 `host.ffmpeg` 能力对象。

`Node_execute` 请求的 `host` 对象由宿主注入，不是清单权限，也不能由插件扩大：它包含 `api_version: 1`、backend 当前开放的 `operations`，以及可选的 `ffmpeg` 能力对象。存在时，`host.ffmpeg` 包含 `api_version: 1`、`max_arguments`、`max_argument_bytes`、`max_total_argument_bytes`，以及 backend 公布的 `options` 和 `filters` 安全允许列表。v1 上限分别为 128 个参数、每项 8192 字节、总计 32768 字节。这些列表是宿主允许的语法范围，不是对当前 FFmpeg 安装所含 codec/filter 的动态探测；宿主可接受的具体处理仍可能因 FFmpeg 构建缺少某 encoder/filter 而失败。插件应按当前列表生成计划；不同 backend 不承诺相同选项。

`ffmpeg.execute` 的返回对象必须且只能包含 `operation` 和 `arguments`；operation 固定为 `ffmpeg.execute`，arguments 是受限的 FFmpeg 输出选项字符串数组，不是完整命令行。插件不能指定输入/输出路径、第二个输入、任意命令或 shell 字符串。宿主绑定节点图中的唯一输入/输出，并在现有队列执行；没有任意 shell、任意 FFmpeg 参数或 native DLL/SO 加载能力。

backend 当前公布的输出选项白名单为：`-c:v`、`-c:a`、`-b:v`、`-b:a`、`-crf`、`-q:v`、`-preset`、`-pix_fmt`、`-r`、`-ar`、`-ac`、`-frames:v`、`-t`、`-ss`、`-map`、`-vf`、`-af`、`-filter_complex`、`-f`、`-an`、`-vn`、`-shortest`。值也按选项类型单独校验，包括 codec、preset、pixel format、muxer 的白名单、数值范围和媒体类型限制；重复选项不接受（`-map` 除外）。图片不能使用 `-f` 指定 muxer，并且输出强制为单帧。

滤镜白名单分为：视频 `null`、`scale`、`crop`、`pad`、`hflip`、`vflip`、`transpose`、`rotate`、`format`、`eq`、`hue`、`setsar`、`setdar`、`fps`、`trim`、`setpts`、`split`、`overlay`、`fade`、`unsharp`、`boxblur`、`gblur`、`hqdn3d`、`yadif`、`bwdif`、`reverse`；音频 `anull`、`volume`、`atempo`、`atrim`、`asetpts`、`afade`、`aformat`、`aresample`、`loudnorm`、`dynaudnorm`、`highpass`、`lowpass`、`equalizer`、`bass`、`treble`、`acompressor`、`agate`、`alimiter`、`asplit`、`amix`、`amerge`、`areverse`；音频可视化 `showwavespic` 和 `showspectrumpic`。这些仍只是允许的滤镜名称，不保证某个 FFmpeg 构建实际包含对应实现。 音频可视化滤镜仅能置于 `-filter_complex` 图中使用。

滤镜图采用刻意缩小的语法：最多 64 个滤镜节点；不支持引号、反斜杠转义、空白、`@` 实例名或从文件加载的选项。滤镜选项以受限的冒号分隔字段书写，例如 `scale=iw/2:ih/2`；不支持需要逗号转义的任意表达式。多个链只适用于 `-filter_complex`，并且该选项不能与 `-vf`/`-af` 混用。复杂滤镜链只能从绑定的当前输入媒体标签（如 `0:v`、`0:a`）开始，输出标签必须在当前图中本地定义。`-map` 可引用当前输入流或本地图输出标签（最多 16 项）；不能增加额外输入。`split`/`asplit` 最多输出 16 路。

跨媒体转换时，默认输出后缀按目标类型使用 WAV、MKV、PNG；同类型处理保留原有输出后缀规则，临时文件也使用对应目标类型后缀。最终输出为图像时，视频格式设置不会覆盖图像后缀；自定义输出名的扩展名会归一为图像格式，并在目标文件已存在时选择不冲突的文件名。支持的图片容器会被限制为单帧，实际编码仍受当前 FFmpeg 构建支持的 encoder/filter 影响。

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
