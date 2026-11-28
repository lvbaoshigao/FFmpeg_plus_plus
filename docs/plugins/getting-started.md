# 编译并运行第一个插件

本例使用无 libc 的 C 代码构建 Audio Gain 节点，默认降低音量 6 dB。它通过宿主现有音频处理流程执行，不读取媒体文件、不直接启动 FFmpeg，也不申请网络权限。

## 1. 导出 SDK 并安装工具链

在插件页的新增入口选择导出 SDK，解压后保留目录结构。SDK 含头文件、JSON Schema、可编译示例、数据包示例与 Python 构建脚本；**不捆绑编译器**。

先访问 [WebAssembly 官方开发者指南](https://webassembly.org/getting-started/developers-guide/)。WebAssembly 是编译目标与规范，官网不会提供一个统一的“WebAssembly 编译器安装包”。C/C++ 开发者可选择：

| 工具链 | 获取入口 | 本插件的使用方式 |
| --- | --- | --- |
| WASI SDK | [WebAssembly/wasi-sdk releases](https://github.com/WebAssembly/wasi-sdk/releases) | 设置 WASI_SDK_PATH，使用其 bin/clang 与 wasm-ld |
| Emscripten | [官方 emsdk 安装指南](https://emscripten.org/docs/getting_started/downloads.html) | 按官方步骤安装激活后，使用 upstream/bin/clang，而非生成 JS 胶水的 emcc 默认模式 |
| LLVM | [LLVM releases](https://releases.llvm.org/) | 安装支持 wasm32 的 clang 和 wasm-ld |

SDK 显式使用 --target=wasm32 -nostdlib，因此即使用 WASI SDK 的编译器，也不生成带 WASI 导入的程序。C++ 源按 C++17 编译，不包含 C++ 标准库，并关闭 exceptions/RTTI。不要添加 _start、_initialize、线程、SIMD、浏览器 DOM 或 Emscripten JS 运行时依赖。构建需 Python 3.9+；有自动或显式自测用例时还需 Node.js。

## 2. 实际编译和打包

在解压的 SDK 根目录执行：

~~~sh
python3 tools/build_plugin.py --self-test
~~~

Windows PowerShell 可执行：

~~~powershell
py -3 tools/build_plugin.py --clang "C:/tools/wasi-sdk/bin/clang.exe" --self-test
~~~

如果 clang 找不到 WASM 链接器，可补充 --wasm-ld 参数。脚本不调用 shell、不自动下载依赖，编译或自测失败会返回非零退出码。输出为 dist/audio-gain.fppplugin。

脚本从清单生成元数据头，避免 Basic_info 与 Node_info 在清单和代码中漂移。它使用 --no-entry 和有界线性内存；四个业务函数均为 void(void)，仅导入 request_read 与 response_write。自测真实实例化 WASM 并执行 16 组输入，覆盖元数据、宿主表单字段、合法增益、错误媒体/节点、越界参数和过长请求。

在仓库根目录复现已发布的示例及运行时 fixture：

~~~sh
python3 plugin_sdk/tools/build_plugin.py --output docs/public/examples/plugin-demo.fppplugin --emit-wasm docs/public/examples/plugin-demo.wasm --self-test --fixtures docs/public/examples/plugin-fixtures/selftest.json
~~~

可直接下载 [已编译插件包](/examples/plugin-demo.fppplugin)、[WASM 模块](/examples/plugin-demo.wasm) 和 [自测请求/响应](/examples/plugin-fixtures/selftest.json)。Node 自测验证 ABI 和示例逻辑；应用内采用原生 WASM 沙箱，还需要通过应用运行时测试。

## 3. 导入并启用

1. 打开设置中的插件实验开关，从桌面侧栏或移动底栏进入插件页。
2. 导入插件包，确认 ID、版本、描述和声明节点。安装本身不会运行节点或自动启用。
3. 点击“启用插件”，核对来源并阅读首次启用风险提示：应用只校验格式与兼容性，不对插件代码做安全检测或审计，使用者需自行评估。预览版还需确认稳定性提示。本例没有文件/网络权限，无需额外授予。
4. 若后端未编入 WASM 运行时、应用版本不符或声明与导出信息不符，启用会失败；保留错误信息检查构建与清单。设置已开启而运行时不可用时，插件页会单独说明运行时尚未就绪。
5. 使用“节点配置”逐项选择需要的节点；更改会保存。禁用某个节点不会删除现有图中的参数，但会阻止该节点运行，重新启用后可继续使用。

## 4. 在现有节点图中运行

导入一个测试音频，打开节点编辑器，在插件节点中添加 Audio Gain。按正常方式连接 **音频开始 → Audio Gain → 输出**，设置输出文件后运行。把 Gain (dB) 设为 -6 时，WASM 接收经宿主验证的参数并返回：

~~~json
{"operation":"audio.volume","decibels":-6}
~~~

宿主校验媒体类型和数值后构造现有 BackendCall，任务进入正常队列。可用逻辑门控制其使能端；IsLogic 仅表示接受已有控制机制，不把媒体节点变为布尔逻辑门。禁用/卸载插件后，该节点数据仍可保留，但不能继续执行。

需要可重复的源文件时，可在装有 FFmpeg 的开发机生成 1 秒正弦测试音频：

~~~sh
ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -c:a pcm_s16le input.wav
~~~

分别输出 0 dB 与 -6 dB，比较音量分析或波形，确认图中的参数影响了实际处理结果；避免用是否“出现节点”替代运行验证。

## 5. 修改并分发

先修改清单中的插件 ID 与版本，再修改 C 或 C++ 实现。不要改变已有节点 ID 或无迁移方案地重解释参数。重新编译、运行自测并在应用中导入测试后分发插件包。SDK、ABI 与清单详见 [API 参考](./api.md)，发布前检查 [安全与兼容性](./security.md)。

## 6. 编写 C/C++ 媒体节点

SDK 允许将插件自己的 C/C++ 业务代码编译为 freestanding WASM；它不加载 native DLL/SO，也不让 guest 直接访问 FFmpeg、shell、媒体路径或输入/输出文件。可从 SDK `examples/media-toolkit/` 查看 `video_tone`、`audio_normalize` 与 `audio_waveform` 三节点示例：前两者在同类型视频/音频上处理，波形节点把音频转换为单帧图片。Node_info 仍固定一入一出；声明 `input_types` 与 `output_type`，只有 `ffmpeg.execute` 可跨类型转换。

`Node_execute` 请求带有当前输入类型的 `media_type`/`input_media_type`、由 live 节点声明确定的 `output_media_type`，以及宿主注入的 `host` capabilities。使用 `ffmpegpp_json.h` 中的 `fpp_json_parse`、typed getters 与 `fpp_host_capabilities_init` 读取请求、参数和当前 advertised capabilities；由 `fpp_host_supports_operation`/`fpp_host_supports_ffmpeg_option`/`fpp_host_supports_ffmpeg_filter` 检查对应能力。用 `ffmpegpp_ffmpeg.h` 的 plan writer 构造输出；`fpp_ffmpeg_plan_add_filter` 只适用于简单视频 `-vf`，`-af` 与 `-filter_complex` 通过 `fpp_ffmpeg_plan_add_option` 传入。不要写死 backend 选项列表；后端仍会执行完整语法及 UTF-8 字节限制校验。`ffmpeg.execute` 结果仅为 {"operation":"ffmpeg.execute","arguments":[...strings]}。参数只放允许的输出选项/滤镜；宿主绑定当前图中的唯一输入和输出，通过普通任务队列执行，保留进度、暂停和取消。

跨媒体转换的默认输出扩展名为目标类型对应的 WAV（音频）、MKV（视频）或 PNG（图像）；同类型流程沿用现有后缀，临时文件也匹配目标类型。最终图像输出不受视频格式设置覆盖，自定义输出名的扩展会归一为图像格式并避让已有文件。实际是否支持选定的编码器/滤镜仍取决于运行时 FFmpeg 构建。`ffmpeg.execute` 的精确参数和语法边界见 [API 参考](./api.md)。

`media-toolkit` 的 `build.json` 声明多源编译，`selftest.json` 会在构建时自动运行（需要 Node.js）。`--source` 可重复传入、相对 `--example` 目录，并覆盖 `build.json`；`--test-cases` 可改用外部 case 文件，接受用例数组或包含 `cases` 数组的对象。单次用例包含 `name`、`entry`、`request`、`response`；多步用例用 `name` 与 `steps` 数组描述每轮请求和预期响应，步骤可继承用例的 `entry`。每次调用（包括每一步）都使用新的 WASM 实例，续调请求需在用例中明确给出。自定义用例仍会独立校验清单元数据。解压 SDK 后，在 SDK 根目录执行：

~~~sh
python3 tools/build_plugin.py --example examples/media-toolkit --output dist/media-toolkit.fppplugin --emit-wasm dist/media-toolkit.wasm --self-test --fixtures dist/media-toolkit-selftest.json
~~~

可直接下载 [Media Toolkit 插件包](/examples/media-toolkit.fppplugin)、[WASM 模块](/examples/media-toolkit.wasm) 和 [自测请求/响应](/examples/plugin-fixtures/media-toolkit-selftest.json)。在仓库根目录复现这些下载产物：

~~~sh
python3 plugin_sdk/tools/build_plugin.py --example plugin_sdk/examples/media-toolkit --output docs/public/examples/media-toolkit.fppplugin --emit-wasm docs/public/examples/media-toolkit.wasm --self-test --fixtures docs/public/examples/plugin-fixtures/media-toolkit-selftest.json
~~~

导入并启用后，可分别连接 **视频开始 → Video Tone → 输出**、**音频开始 → Audio Normalize → 输出**，或 **音频开始 → Audio Waveform → 输出** 验证三类处理。波形节点输出单帧 PNG；运行前确认后端已提供 `ffmpeg.execute`，且当前 FFmpeg 构建包含示例使用的 `eq`、`hue`、`loudnorm` 和 `showwavespic` 滤镜。
